"""Drive the frontend in a headless browser against dev, as a person would, and report every console
error, failed API call and widget error on the way. Screenshots go to logs/web-check/.

    uv run python -m api --env-file .env.api serve          # terminal 1
    cd web && npm run dev                                   # terminal 2
    uv run --with playwright python tools/web_check.py --env-file .env.api

The env file is the API's for dev, plus dev's superuser (DB_USER, DB_PASSWORD), as for api/tests:
the check creates a super admin and a user of its own and removes them, with everything they
did, afterwards. It refuses any database whose DB_LABEL isn't dev. Playwright needs a Chromium:
`uv run --with playwright playwright install chromium`, or --chromium to name one already there.

The flow: log in and change the temporary password; open the accounts page and create a user;
choose the site; start from tenant 3's template; set a range dev has data for; pick a node so the
channel's widgets follow; narrow to two hours so readings go to minutes and Now has readings; enter
edit mode from a widget's Edit, add a Stat on channel A and find its figure and line; save, reload
and find it as saved; look at the bottom bar's data health; star a node and find it starred after a
reload; open the category tree; click a node in the single-line diagram; export the dashboard and
import the file; then at phone width. Last, three Readings widgets of other nodes, quantities and
intervals share their tooltip: hovering one shows the others' at the same time, and leaving clears all.
Then a Node information widget: a board's feeders and loads, its meter on both the board and its
feeder edge, with gateway and slave address, and a click on a load moving the channel there.
"""
import argparse
import asyncio
import datetime
import json
import pathlib
import sys
import uuid

import psycopg
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from api import app, config  # noqa: E402
from server.config import parse_env_file  # noqa: E402

PASSWORD = "web check password 2026"
DAY = "2026-10-21"       # a site day with minute data, 15-minute buckets and the daily summary on dev
TOOLTIP_NODES = ("AJL1", "COMP_ELITE")    # metered, with current and power in 15-minute buckets on dev
INFO_NODE = "LVMDB_A5"   # its meter LVA5 is on its feeder edge from FACTORY_AB (energy) and on the board (THD)


def remove(su, pattern):
    """Every account matching pattern, and what it left behind."""
    with psycopg.connect(**su) as conn:
        ids = [r[0] for r in conn.execute("SELECT id FROM frontend.app_user WHERE email LIKE %s", (pattern,))]
        conn.execute("DELETE FROM frontend.audit WHERE actor_id = ANY(%s) OR target_user_id = ANY(%s) OR email LIKE %s",
                     (ids, ids, pattern))
        conn.execute("DELETE FROM frontend.session WHERE user_id = ANY(%s)", (ids,))
        conn.execute("DELETE FROM frontend.dashboard WHERE owner_id = ANY(%s)", (ids,))
        conn.execute("UPDATE frontend.app_user SET created_by = NULL WHERE id = ANY(%s)", (ids,))
        conn.execute("DELETE FROM frontend.app_user WHERE id = ANY(%s)", (ids,))
    return len(ids)


def node_ids(su, codes):
    """Today's node id of each code."""
    with psycopg.connect(**su) as conn:
        rows = conn.execute("""SELECT node_code, id FROM graph.node
            WHERE tenant_id = 3 AND node_code = ANY(%s) AND is_active AND effective_from <= CURRENT_DATE
              AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)""", (list(codes),)).fetchall()
    ids = dict(rows)
    missing = set(codes) - ids.keys()
    if missing:
        sys.exit(f"web_check: no node {', '.join(sorted(missing))} in effect on dev")
    return ids


def shared_tooltip(page, out, nodes):
    """Three Readings widgets: one node's three currents hourly, another's power at 15 minutes, and the
    same power narrower. A tooltip shows in every chart at the hovered time, each at its own nearest
    point, whatever the hovered chart's series or point count."""
    def widget(wid, title, x, y, w, node, quantities, interval):
        return {"id": wid, "type": "readings", "title": title, "x": x, "y": y, "w": w, "h": 9, "channel": None,
                "settings": {"node": node, "quantities": quantities, "interval": interval}}
    a, b = (nodes[c] for c in TOOLTIP_NODES)
    doc = {"time": {"from": "2026-10-20", "to": "2026-10-21"}, "refresh": None, "channels": {}, "widgets": [
        widget("current", "Currents, hourly", 0, 0, 12, a, ["CURRENT_A", "CURRENT_B", "CURRENT_C"], "hour"),
        widget("power", "Power, 15 minutes", 12, 0, 12, b, ["ACTIVE_POWER"], "15min"),
        widget("narrow", "Power, narrow", 0, 9, 7, b, ["ACTIVE_POWER"], "auto")]}
    f = out / "shared-tooltip.json"
    f.write_text(json.dumps({"kind": "o-mcp/dashboard-export", "tenant": 3, "exported_at": "2026-10-27T00:00:00Z",
                             "title": "Shared tooltip", "format_version": 1, "document": doc}))
    page.click(".brand")
    page.wait_for_selector("text=Dashboards · PRS")
    page.set_input_files(".file-button input", str(f))
    page.wait_for_url(lambda u: "/dashboards/" in u)
    page.wait_for_function("() => document.querySelectorAll('.widget .chart canvas').length === 3", timeout=180_000)
    page.wait_for_function("() => !document.querySelector('.loading')", timeout=180_000)
    page.wait_for_timeout(1500)

    def tips():
        """Each chart's visible tooltip time, or None."""
        return page.evaluate("""() => [...document.querySelectorAll('.widget .chart')].map(c => {
            const t = c.children[1];
            if (!t) return null;
            const s = getComputedStyle(t);
            const hidden = s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0';
            return hidden || !t.innerText.trim() ? null : t.innerText.split('\\n')[0];
        })""")

    def hover(i, frac, name):
        box = page.locator(".widget .chart").nth(i).bounding_box()
        page.mouse.move(box["x"] + box["width"] * frac, box["y"] + box["height"] / 2, steps=5)
        page.wait_for_timeout(600)
        page.screenshot(path=str(out / f"7-tooltip-{name}.png"))
        return tips()

    found = []
    t = hover(0, 0.35, "hourly")
    if None in t or len(set(t)) != 1:
        found.append(f"shared tooltip: hovering the hourly chart shows {t}")
    t = hover(1, 0.62, "15min")
    if None in t or t[1] != t[2]:
        found.append(f"shared tooltip: hovering the 15-minute chart shows {t}")
    else:
        hourly, quarter = (datetime.datetime.fromisoformat(v) for v in t[:2])
        if hourly.minute or abs(hourly - quarter) > datetime.timedelta(minutes=30):
            found.append(f"shared tooltip: the hourly chart shows {t[0]} for {t[1]}")
    page.mouse.move(5, 5)
    page.wait_for_timeout(600)
    page.screenshot(path=str(out / "7-tooltip-left.png"))
    if any(tips()):
        found.append(f"shared tooltip: still shown after leaving: {tips()}")
    return found


def node_info(page, out, nodes):
    """A Node information widget on channel A, holding LVMDB_A5: what feeds it, with LVA5 on the
    transformer edge; LVA5 on both the node and the edge, with its gateway and slave address; a click
    on a node it feeds moves the channel there."""
    doc = {"time": {"from": "2026-10-20", "to": "2026-10-21"}, "refresh": None,
           "channels": {"A": {"kind": "node", "id": nodes[INFO_NODE]}},
           "widgets": [{"id": "info", "type": "nodeinfo", "title": "Node information", "x": 0, "y": 0, "w": 16,
                        "h": 12, "channel": "A", "settings": {"node": None}}]}
    f = out / "node-info.json"
    f.write_text(json.dumps({"kind": "o-mcp/dashboard-export", "tenant": 3, "exported_at": "2026-10-28T00:00:00Z",
                             "title": "Node information", "format_version": 1, "document": doc}))
    page.click(".brand")
    page.wait_for_selector("text=Dashboards · PRS")
    page.set_input_files(".file-button input", str(f))
    page.wait_for_url(lambda u: "/dashboards/" in u)
    page.wait_for_selector(".widget h4:has-text('Devices')", timeout=180_000)
    page.wait_for_function("() => !document.querySelector('.loading')", timeout=180_000)
    page.screenshot(path=str(out / "8-node-info.png"))
    found = []
    tables = page.locator(".widget .grid-table")
    fed, feeds, devices = (tables.nth(i).inner_text() for i in range(3))
    if "FACTORY_AB" not in fed or "LVA5" not in fed:
        found.append(f"node information: Fed by doesn't show LVA5 on the edge from FACTORY_AB: {fed!r}")
    if "COMP_300HP" not in feeds:
        found.append(f"node information: Feeds doesn't list COMP_300HP: {feeds!r}")
    for want in ("LVA5", "node", "edge from FACTORY_AB", "192.168.20.13:502", "28"):
        if want not in devices:
            found.append(f"node information: Devices doesn't show {want!r}: {devices!r}")
    tables.nth(1).locator("button:has-text('COMP_300HP')").click()
    page.wait_for_selector(".channel:has-text('COMP_300HP')")
    page.wait_for_selector(".widget .pad:has-text('COMP_300HP')", timeout=180_000)
    page.screenshot(path=str(out / "8b-node-info-followed.png"))
    return found


def drive(page, url, email, temp, out, problems, nodes):
    def settle():
        page.wait_for_function("() => !document.querySelector('.loading')", timeout=180_000)
        page.wait_for_timeout(1500)       # chart animations

    def time_range(start, end):
        page.click(".toolbar .popover-anchor > button")
        page.fill(".time-picker .custom label:nth-child(1) input", start)
        page.fill(".time-picker .custom label:nth-child(2) input", end)
        page.click(".time-picker .custom button")

    page.goto(url)
    page.fill("input[type=email]", email)
    page.fill("input[type=password]", temp)
    page.click("button[type=submit]")
    page.wait_for_selector("text=Choose your own password")
    pw = page.locator("input[type=password]")
    for i, p in enumerate((temp, PASSWORD, PASSWORD)):
        pw.nth(i).fill(p)
    page.click("button[type=submit]")
    page.wait_for_selector("h2:has-text('Choose a site')")
    problems.clear()    # before logging in, /api/me is 401 by design

    page.click("text=Accounts")
    page.fill(".new-account input[type=email]", email.replace("web-check", "web-check-user"))
    page.click(".new-account button[type=submit]")
    page.wait_for_selector(".notice .secret")
    page.wait_for_selector(f"td:has-text('{email.replace('web-check', 'web-check-user')}')")
    page.screenshot(path=str(out / "1-accounts.png"))
    page.click(".brand")

    page.select_option("select.tenant", "3")
    page.wait_for_selector("text=Dashboards · PRS")
    page.click("text=New from “Energy overview”")
    page.wait_for_selector(".toolbar")
    time_range("2026-10-20", "2026-10-22")
    settle()
    page.screenshot(path=str(out / "2-template.png"))

    # the left panel's Find: type groups, the utility and metered filters, a click sets channel A
    page.fill(".left .find-filters input[placeholder='Find a node']", "LVMDB_A")
    page.click(".left .find-filters .utilities button:has-text('Electricity')")
    page.check(".left .find-filters input[type=checkbox]")
    page.wait_for_selector(".left details[open] summary:has-text('MAIN_LV_BOARD')")
    page.click(".left li:has-text('LVMDB_A5') .pick")
    page.wait_for_selector(".channel:has-text('LVMDB_A5')")
    time_range(f"{DAY}T10:00", f"{DAY}T12:00")
    settle()
    page.wait_for_selector("text=minute points")
    page.wait_for_selector(".widget:has-text('Now') td:has-text('PF_TOTAL')")
    page.screenshot(path=str(out / "3-minutes.png"))

    # a Stat on channel A: the node's energy over the two hours as one figure, with its line; edit
    # mode from a widget's own Edit, shown on hover
    edit = page.locator(".widget:has-text('Energy flow') header .hover-only button")
    page.mouse.move(0, 0)
    if edit.is_visible():
        problems.append("widget: Edit shown without hover")
    page.hover(".widget:has-text('Energy flow') header")
    edit.click()
    page.wait_for_selector(".toolbar button:text-is('Done editing')")
    page.locator(".toolbar select").filter(has_text="Add a widget").select_option("stat")
    stat = page.locator(".widget").last
    stat.locator("header select").select_option("A")
    page.click(".toolbar button:text-is('Done editing')")
    page.wait_for_selector(".widget:has-text('ACTIVE_ENERGY_DELIVERED · total') .stat .chart canvas")
    settle()
    figure = stat.locator(".stat-figure").inner_text()
    if not any(ch.isdigit() for ch in figure):
        problems.append(f"stat: no figure ({figure!r})")
    stat.scroll_into_view_if_needed()
    page.screenshot(path=str(out / "3b-stat.png"))

    page.click("text=Save")
    page.wait_for_selector("button:has-text('Saved')")
    first = page.url.rstrip("/").rsplit("/", 1)[-1]
    page.reload()
    page.wait_for_selector(".channel:has-text('LVMDB_A5')")
    settle()
    page.wait_for_selector(".bottombar :text('meters silent')")

    # the left panel: star a node, find it starred after a reload, and the category tree
    page.fill(".left .find-filters input[placeholder='Find a node']", "LVMDB_A5")
    page.click(".left li:has-text('LVMDB_A5') .star")
    page.wait_for_selector(".left li:has-text('LVMDB_A5') .star.on")
    page.reload()
    page.click(".left .tabs button:has-text('Starred')")
    page.wait_for_selector(".left li:has-text('LVMDB_A5') .star.on")
    page.click(".left .tabs button:has-text('Categories')")
    page.wait_for_selector(".category-tree summary:has-text('Production')")
    settle()

    # the single-line diagram: a click on a node's code puts it on the channel
    sld = ".widget:has-text('What it feeds') .sld"
    page.wait_for_selector(f"{sld} svg")
    page.evaluate("document.querySelector('main').scrollTo(0, 99999)")
    page.screenshot(path=str(out / "4-lower.png"))
    code = page.get_attribute(f"{sld} [data-node]:not([data-node='LVMDB_A5'])", "data-node")
    page.click(f"{sld} [data-node='{code}']")
    page.wait_for_selector(f".channel:has-text('{code}')")
    settle()
    page.screenshot(path=str(out / "5-diagram.png"))

    # export, and import the file as a new dashboard
    page.click("text=Discard")
    page.wait_for_selector("button:has-text('Saved')")
    with page.expect_download() as d:
        page.click("button:has-text('Export')")
    exported = out / "export.json"
    d.value.save_as(str(exported))
    page.click(".brand")
    page.set_input_files(".file-button input", str(exported))
    page.wait_for_url(lambda u: "/dashboards/" in u and not u.endswith(f"/{first}"))
    page.wait_for_selector(".channel:has-text('LVMDB_A5')")
    settle()
    page.set_viewport_size({"width": 400, "height": 900})
    page.wait_for_timeout(1500)
    wide = page.evaluate("document.documentElement.scrollWidth")
    page.screenshot(path=str(out / "6-phone.png"))
    found = [f"widget error: {t}" for t in page.locator(".widget .error").all_inner_texts()] + \
        ([f"the page is {wide} px wide at a 400 px screen"] if wide > 400 else [])

    page.set_viewport_size({"width": 1600, "height": 1000})
    found += shared_tooltip(page, out, nodes)
    found += node_info(page, out, nodes)
    return found + [f"widget error: {t}" for t in page.locator(".widget .error").all_inner_texts()]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--env-file", required=True)
    ap.add_argument("--url", default="http://localhost:5173/")
    ap.add_argument("--chromium", help="a Chromium or headless shell to use instead of Playwright's own")
    ap.add_argument("--out", default=str(ROOT / "logs" / "web-check"))
    a = ap.parse_args()
    cfg = config.load(a.env_file)
    if cfg.db_label != "dev":
        sys.exit(f"web_check: {a.env_file} targets {cfg.db_label}, not dev")
    raw = parse_env_file(a.env_file)
    su = dict(host=cfg.db_host, port=cfg.db_port, dbname=cfg.db_name, user=raw["DB_USER"],
              password=raw["DB_PASSWORD"], sslmode=cfg.db_sslmode)
    nodes = node_ids(su, TOOLTIP_NODES + (INFO_NODE,))
    run = uuid.uuid4().hex[:8]
    email = f"web-check+{run}@example.com"
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    problems = []
    temp = asyncio.run(app.create_super_admin(cfg, email))
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(executable_path=a.chromium)
            page = browser.new_page(viewport={"width": 1600, "height": 1000})
            page.on("console", lambda m: m.type == "error" and problems.append(f"console: {m.text}"))
            page.on("pageerror", lambda e: problems.append(f"page error: {e}"))
            page.on("dialog", lambda d: (problems.append(f"dialog: {d.message}"), d.dismiss()))
            page.on("response", lambda r: r.status >= 400 and "/api/" in r.url
                    and problems.append(f"{r.status} {r.request.method} {r.url}"))
            try:
                problems += drive(page, a.url, email, temp, out, problems, nodes)
            except Exception as e:
                problems.append(f"stopped: {e}".splitlines()[0])
                page.screenshot(path=str(out / "failed.png"))
            browser.close()
    finally:
        removed = remove(su, f"%+{run}@example.com")
    print(f"screenshots in {out}; removed {removed} test account(s)")
    print("\n".join(problems) or "no problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
