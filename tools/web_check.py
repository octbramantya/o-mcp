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
reload; open the category tree and fold and unfold its headings by keyboard and click; click a node
in the single-line diagram; export the dashboard and import the file; then at phone width. Last,
three Readings widgets of other nodes, quantities and intervals share their tooltip: hovering one
shows the others' at the same time, and leaving clears all.
Then the side bar's Reference view, from the dashboard list: a board's feeders and loads, its meter
on both the board and its feeder edge, with gateway and slave address; that meter's page, where the
model reads it and what it reported, with no reading times; a quantity's page listing the devices
read for it, a meter on another board among them; Back; a search by device; a node's values; ⓘ in
Find on a dashboard opening Reference without moving the channel; and a saved Meters widget drawn
as a placeholder pointing at Reference. Both searches by keyboard: Reference's matches by the arrow
keys and Enter while typing, "N more", and Escape clearing either field.
Then units and Compare: a Readings widget of two units on a dual axis and one of three in panels,
and two Compare widgets, power across two loads and energy across boards with an unmetered panel
listed as "no meter"; hovering the dual-axis chart shows the panels' tooltip too. The content-bearing
hints as tooltips, by hover and by keyboard (an Aggregate's P95 and Readings). From and To's calendars.
The single-line diagram with figures: INCOMING_PLN three levels down (121 nodes, three batches of
/api/aggregate) with each node's energy over a day, measured in bold and worked out in italics, a
click on a figure putting its node on the channel, and the legend shown under the drawing on request;
and FACTORY_AB with readings at the range's end, LVA5's on its feeder rather than on LVMDB_A5,
exported as one SVG with its figures, legend and caption. Then the React Aria controls by keyboard
(design/frontend-aria.md); one widget in full screen with its settings panel, back by the button
and by the browser's Back; a drag on Readings and Compare zooming the range, and ↶ back; and last the
controls' overlays at a 400 px phone screen.
"""
import argparse
import asyncio
import datetime
import json
import pathlib
import re
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
UNMETERED = "FLR_124"    # an unmetered panel on LVMDP_SPINNING_1 (056)
INFO_NODE = "LVMDB_A5"   # its meter LVA5 is on its feeder edge from FACTORY_AB (energy) and on the board (THD)
METERS_NODE = "LVMDB_A4"  # read by LVA4, and by PLTSC x 1/3 on active energy delivered (048)
REF = ".side-bar .reference"
SLD_ROOT = "INCOMING_PLN"   # three levels down: 121 nodes, more than one /api/aggregate call holds


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


def reference(page, out, nodes):
    """The Reference view, from the dashboard list: LVMDB_A5 fed from FACTORY_AB through LVA5, feeding
    COMP_300HP, with LVA5 on the node and the feeder and its gateway and slave address; LVA5's page;
    ACTIVE_ENERGY_DELIVERED's, with PLTSC at LVMDB_A4 among the devices read for it; Back twice; PLTSC
    found by search, with its register details; LVMDB_A4's values; and nowhere a time of day."""
    found = []
    page.click(".brand")
    page.wait_for_selector("text=Dashboards · PRS")
    page.click(".activity-bar button[aria-label='Reference'][aria-checked=false]")
    search = f"{REF} .ref-head input"
    reads = f"{REF} section:has(h4:has-text('Where the model reads it'))"

    def look_up(text, kind):
        page.fill(search, text)
        page.wait_for_selector(f"{REF} .search-header", timeout=180_000)
        section = f"{REF} .search-section:has(.search-header:has-text('{kind}'))"
        page.click(f"{section} [role=option]:has(b:text-is('{text}'))")
        page.wait_for_selector(f"{REF} .ref-title b:text-is('{text}')")
        page.wait_for_function("() => !document.querySelector('.side-bar .loading')", timeout=180_000)

    def section(title):
        return page.locator(f"{REF} section:has(h4:has-text('{title}'))").inner_text()

    def no_time(where):
        shown = page.locator(REF).inner_text()
        if re.search(r"\b\d{2}:\d{2}\b", shown):
            found.append(f"reference: the {where} page shows a time of day: {shown!r}")

    look_up(INFO_NODE, "Nodes")
    page.wait_for_selector(f"{REF} h4:has-text('Values at this node')", timeout=180_000)
    page.screenshot(path=str(out / "8-reference-node.png"))
    fed, feeds, devices = section("Fed by"), section("Feeds"), section("Devices")
    if "FACTORY_AB" not in fed or "LVA5" not in fed:
        found.append(f"reference: Fed by doesn't show LVA5 on the edge from FACTORY_AB: {fed!r}")
    if "COMP_300HP" not in feeds:
        found.append(f"reference: Feeds doesn't list COMP_300HP: {feeds!r}")
    for want in ("LVA5", "node and the feeder from FACTORY_AB", "192.168.20.13:502", "slave ID 28"):
        if want not in devices:
            found.append(f"reference: Devices doesn't show {want!r}: {devices!r}")

    page.click(f"{REF} section:has(h4:has-text('Devices')) .ref-link:has(b:text-is('LVA5'))")
    page.wait_for_selector(f"{REF} .ref-title b:text-is('LVA5')")
    where = section("Where the model reads it")
    if INFO_NODE not in where or "feeder from" not in where or "ACTIVE_ENERGY_DELIVERED" not in where:
        found.append(f"reference: LVA5 isn't read on {INFO_NODE} and its feeder: {where!r}")
    page.screenshot(path=str(out / "8b-reference-device.png"))
    no_time("device")

    page.click(f"{reads} .ref-link:text-is('ACTIVE_ENERGY_DELIVERED')")
    page.wait_for_selector(f"{REF} .ref-title b:text-is('ACTIVE_ENERGY_DELIVERED')")
    read = section("Read by the model")
    if not re.search(rf"PLTSC.*\n.*{METERS_NODE}", read) or "LVA5" not in read:
        found.append(f"reference: ACTIVE_ENERGY_DELIVERED isn't read from PLTSC at {METERS_NODE} and LVA5: {read!r}")
    page.screenshot(path=str(out / "8c-reference-quantity.png"))
    page.click(f"{REF} .ref-head button[aria-label='Back']")
    page.wait_for_selector(f"{REF} .ref-title b:text-is('LVA5')")
    page.click(f"{REF} .ref-head button[aria-label='Back']")
    page.wait_for_selector(f"{REF} .ref-title b:text-is('{INFO_NODE}')")

    look_up("PLTSC", "Devices")
    shown = page.locator(f"{REF} .facts").inner_text()
    for want in ("Surya Nesia", "192.168.20.101:502", "99"):
        if want not in shown:
            found.append(f"reference: PLTSC's register doesn't show {want}: {shown!r}")
    if METERS_NODE not in section("Where the model reads it"):
        found.append(f"reference: PLTSC isn't read at {METERS_NODE}")
    no_time("device")
    page.click(f"{reads} .ref-link:has(b:text-is('{METERS_NODE}'))")
    page.wait_for_selector(f"{REF} h4:has-text('Values at this node')", timeout=180_000)
    values = section("Values at this node")
    if not re.search(r"ACTIVE_ENERGY_DELIVERED.*· measured", values):
        found.append(f"reference: {METERS_NODE}'s values don't have active energy measured: {values!r}")
    page.screenshot(path=str(out / "8d-reference-values.png"))

    # by keyboard: the arrow keys move through the matches while the field keeps focus, Enter opens
    # the one focused, "N more" shows the rest of its kind, and Escape clears the field
    page.fill(search, "LVMDB")
    hits = page.locator(f"{REF} [role=listbox] [role=option]")
    hits.first.wait_for()
    page.keyboard.press("ArrowDown")
    page.keyboard.press("ArrowDown")
    focused = page.locator(f"{REF} [role=option][data-focused] b")
    held = page.evaluate("() => document.activeElement?.getAttribute('aria-label')")
    if held != "Look up a node, device or quantity":
        found.append("reference search: the arrow keys took focus out of the field")
    if not focused.count():
        found.append("reference search: ArrowDown focused no match")
    else:
        code = focused.inner_text()
        page.keyboard.press("Enter")
        page.wait_for_selector(f"{REF} .ref-title b:text-is('{code}')")
        if page.input_value(search):
            found.append(f"reference search: the field kept {page.input_value(search)!r} after Enter")
    page.fill(search, "a")
    more = page.locator(f"{REF} .search-section:has(.search-header:has-text('Nodes')) [role=option]:has-text(' more')")
    shown = page.locator(f"{REF} .search-section:has(.search-header:has-text('Nodes')) [role=option]")
    before = shown.count()
    more.click()
    if more.count() or shown.count() <= before:
        found.append(f"reference search: 'N more' left {shown.count()} nodes shown (from {before})")
    page.screenshot(path=str(out / "8f-reference-search.png"))
    page.locator(search).press("Escape")
    if page.input_value(search) or page.locator(f"{REF} [role=listbox]").count():
        found.append("reference search: Escape didn't clear the field and the matches")
    return found


def retired_and_inspect(page, out, nodes):
    """A saved Meters widget is a placeholder pointing at Reference; on that dashboard, ⓘ beside a node
    in Find opens it in Reference and leaves channel A as it was."""
    doc = {"time": {"from": "2026-10-20", "to": "2026-10-21"}, "refresh": None,
           "channels": {"A": {"kind": "node", "id": nodes[METERS_NODE]}},
           "widgets": [{"id": "meters", "type": "meters", "title": "Meters", "x": 0, "y": 0, "w": 16,
                        "h": 6, "channel": "A", "settings": {"node": None}}]}
    f = out / "retired-meters.json"
    f.write_text(json.dumps({"kind": "o-mcp/dashboard-export", "tenant": 3, "exported_at": "2026-10-30T00:00:00Z",
                             "title": "Retired Meters", "format_version": 1, "document": doc}))
    page.click(".brand")
    page.wait_for_selector("text=Dashboards · PRS")
    page.set_input_files(".file-button input", str(f))
    page.wait_for_url(lambda u: "/dashboards/" in u)
    found = []
    shown = page.locator(".widget .body").inner_text()
    if "Reference view" not in shown:
        found.append(f"retired: the Meters widget isn't a placeholder pointing at Reference: {shown!r}")
    page.click(".activity-bar button[aria-label='Find'][aria-checked=false]")
    page.fill(".side-bar .find-filters input[placeholder='Find a node']", INFO_NODE)
    row = page.locator(f".side-bar li:has-text('{INFO_NODE}')").first
    row.hover()
    row.locator(".inspect").click()
    page.wait_for_selector(f"{REF} .ref-title b:text-is('{INFO_NODE}')")
    if page.locator(f".channel:has-text('{METERS_NODE}')").count() != 1:
        found.append("inspect: ⓘ in Find moved channel A")
    page.screenshot(path=str(out / "8e-inspect.png"))
    return found


def units_and_compare(page, out, nodes):
    """Readings of two units (current and power: a dual axis) and of three (with THD: one panel per
    unit), and Compare: ACTIVE_POWER at two loads, ACTIVE_ENERGY_DELIVERED at two boards and an
    unmetered panel, which is listed as having no meter. Each chart draws, none errs, and the panel
    chart shows its tooltip when the dual-axis one is hovered."""
    a, b = (nodes[c] for c in TOOLTIP_NODES)
    def readings(wid, x, quantities):
        return {"id": wid, "type": "readings", "title": wid, "x": x, "y": 0, "w": 12, "h": 9, "channel": None,
                "settings": {"node": a, "quantities": quantities, "interval": "15min", "axes": "auto"}}
    def compare(wid, x, quantity, ids):
        return {"id": wid, "type": "compare", "title": wid, "x": x, "y": 9, "w": 12, "h": 9, "channel": None,
                "settings": {"quantity": quantity, "nodes": ids, "interval": "auto"}}
    doc = {"time": {"from": "2026-10-20", "to": "2026-10-21"}, "refresh": None, "channels": {}, "widgets": [
        readings("Two units", 0, ["CURRENT_A", "ACTIVE_POWER"]),
        readings("Three units", 12, ["CURRENT_A", "ACTIVE_POWER", "THD_VOLTAGE_LN"]),
        compare("Power at two loads", 0, "ACTIVE_POWER", [a, b]),
        compare("Energy at boards", 12, "ACTIVE_ENERGY_DELIVERED",
                [nodes["LVMDP_SPINNING_1"], nodes["LVMDB_A1"], nodes[UNMETERED]])]}
    f = out / "units-compare.json"
    f.write_text(json.dumps({"kind": "o-mcp/dashboard-export", "tenant": 3, "exported_at": "2026-10-28T00:00:00Z",
                             "title": "Units and Compare", "format_version": 1, "document": doc}))
    discard = page.locator(".toolbar button:has-text('Discard')")
    if discard.count():                   # an earlier step left the channel changed
        discard.click()
        discard.wait_for(state="detached")
    page.click(".brand")
    page.wait_for_selector("text=Dashboards · PRS")
    page.set_input_files(".file-button input", str(f))
    page.wait_for_url(lambda u: "/dashboards/" in u)
    page.wait_for_function("() => document.querySelectorAll('.widget .chart canvas').length === 4", timeout=180_000)
    page.wait_for_function("() => !document.querySelector('.loading')", timeout=180_000)
    page.wait_for_timeout(1500)
    page.screenshot(path=str(out / "9-units-compare.png"))
    found = []
    energy = page.locator(".widget").nth(3).inner_text()
    if f"no meter: {UNMETERED}" not in energy:
        found.append(f"compare: {UNMETERED} isn't listed as having no meter: {energy!r}")
    box = page.locator(".widget .chart").nth(0).bounding_box()
    page.mouse.move(box["x"] + box["width"] * 0.5, box["y"] + box["height"] / 2, steps=5)
    page.wait_for_timeout(600)
    page.screenshot(path=str(out / "9b-units-tooltip.png"))
    shown = page.evaluate("""() => [...document.querySelectorAll('.widget .chart')].map(c => {
        const t = c.children[1];
        const s = t && getComputedStyle(t);
        return !!t && s.display !== 'none' && s.opacity !== '0' && !!t.innerText.trim();
    })""")
    if not all(shown):
        found.append(f"units: hovering the dual-axis chart doesn't show every chart's tooltip: {shown}")
    page.mouse.move(5, 5)
    return found


def sld_values(page, out, nodes):
    """Two plant sections. INCOMING_PLN, three levels, with ACTIVE_ENERGY_DELIVERED at every node over a
    day: a figure at each drawn node, measured and worked-out ones both there, the legend out of the
    drawing until asked for, and a click on a figure putting its node on the channel. FACTORY_AB, one
    level, with PF_TOTAL and THD_VOLTAGE_LN at the range's end (dev's minute data has little else):
    LVA5's readings on its feeder from FACTORY_AB, not on LVMDB_A5."""
    def section(wid, y, node, depth, settings):
        return {"id": wid, "type": "section", "title": wid, "x": 0, "y": y, "w": 24, "h": 16, "channel": "A",
                "settings": {"node": nodes[node], "depth": depth, "direction": "down", "view": "diagram", **settings}}
    doc = {"time": {"from": "2026-10-20", "to": "2026-10-21"}, "refresh": None, "channels": {}, "widgets": [
        section("Diagram with energy", 0, SLD_ROOT, 3, {"quantity": "ACTIVE_ENERGY_DELIVERED"}),
        section("Diagram with readings", 16, "FACTORY_AB", 1, {"live": ["PF_TOTAL", "THD_VOLTAGE_LN"]})]}
    f = out / "sld-values.json"
    f.write_text(json.dumps({"kind": "o-mcp/dashboard-export", "tenant": 3, "exported_at": "2026-11-02T00:00:00Z",
                             "title": "Diagram with figures", "format_version": 1, "document": doc}))
    discard = page.locator(".toolbar button:has-text('Discard')")
    if discard.count():                   # an earlier step left the dashboard changed
        discard.click()
        discard.wait_for(state="detached")
    page.click(".brand")
    page.wait_for_selector("text=Dashboards · PRS")
    page.set_input_files(".file-button input", str(f))
    page.wait_for_url(lambda u: "/dashboards/" in u)
    energy = ".widget:has(header :text('Diagram with energy'))"
    readings = ".widget:has(header :text('Diagram with readings'))"
    page.wait_for_selector(f"{energy} .sld-values text", timeout=180_000)
    page.wait_for_selector(f"{readings} .sld-values text.live", timeout=180_000)
    page.wait_for_function("() => !document.querySelector('.loading')", timeout=180_000)
    found = []
    figures = page.locator(f"{energy} .sld-values text")
    if figures.count() < 100:
        found.append(f"sld values: {figures.count()} figures on {SLD_ROOT}'s diagram")
    for kind in ("measured", "solved"):
        if not page.locator(f"{energy} .sld-values text.{kind}").count():
            found.append(f"sld values: no {kind} figure")
    if page.locator(".widget .sld-legend").count():
        found.append("sld values: the legend is shown before it was asked for")
    if page.locator(".widget .sld svg :text('Legend:')").count():
        found.append("sld values: the drawing has a legend in it")
    missing = page.locator(f"{energy} .tip-trigger:has-text('without a figure')")
    if missing.count():
        missing.hover()
        try:
            page.get_by_role("tooltip").filter(has_text="for why").wait_for(timeout=3000)
        except Exception:
            found.append("sld values: 'without a figure' shows no tooltip")
        page.mouse.move(5, 5)

    feeder = page.locator(f"{readings} .sld-values text.live[data-feeder='FACTORY_AB>LVMDB_A5']")
    if feeder.count() != 2 or "LVA5" not in (feeder.first.locator("title").text_content() or ""):
        found.append(f"sld readings: LVA5 isn't on its feeder ({feeder.count()} figures there)")
    on_node = page.locator(f"{readings} .sld-values text:not([data-feeder])[data-node='LVMDB_A5'] title")
    on_node = on_node.all_text_contents()
    if any("LVA5" in t for t in on_node):
        found.append("sld readings: LVA5's readings are on LVMDB_A5's node as well as its feeder")
    page.locator(f"{readings}").scroll_into_view_if_needed()
    page.click(f"{readings} .foot button:text-is('Actual size')")
    page.screenshot(path=str(out / "10c-sld-readings.png"))
    with page.expect_download() as dl:
        page.click(f"{readings} .foot button:text-is('Export SVG')")
    svg = out / dl.value.suggested_filename
    dl.value.save_as(str(svg))
    text = svg.read_text()
    if not (svg.name.startswith("sld_FACTORY_AB_d1_") and "Legend:" in text and "LVA5" in text
            and "PF_TOTAL, THD_VOLTAGE_LN at" in text and text.rstrip().endswith("</svg>")):
        found.append(f"sld export: {svg.name} lacks the legend, LVA5's readings or the caption")

    page.locator(f"{energy}").scroll_into_view_if_needed()
    page.click(f"{energy} .foot button:text-is('Legend')")
    page.wait_for_selector(f"{energy} .sld-legend")
    page.screenshot(path=str(out / "10-sld-values.png"))
    page.click(f"{energy} .foot button:text-is('Actual size')")
    page.locator(f"{energy} .sld-values text.measured").first.scroll_into_view_if_needed()
    page.screenshot(path=str(out / "10b-sld-values-actual.png"))
    solved = page.locator(f"{energy} .sld-values text.solved").first
    code = solved.get_attribute("data-node")
    solved.click()
    page.wait_for_selector(f".channel:has-text('{code}')")
    return found


def tooltips(page, out, nodes):
    """The hints that carry content are tooltips (design/frontend-aria.md phase 10): an Aggregate of
    power at two loads shows P95's on hover, Escape hides it, and Tab from P95 to Readings shows that
    one's by keyboard; a page with no `title` beside either."""
    a, b = (nodes[c] for c in TOOLTIP_NODES)
    doc = {"time": {"from": "2026-10-20", "to": "2026-10-21"}, "refresh": None, "channels": {}, "widgets": [
        {"id": "spread", "type": "value", "title": "Power spread", "x": 0, "y": 0, "w": 16, "h": 6, "channel": None,
         "settings": {"quantity": "ACTIVE_POWER", "nodes": [a, b]}}]}
    f = out / "tooltips.json"
    f.write_text(json.dumps({"kind": "o-mcp/dashboard-export", "tenant": 3, "exported_at": "2026-11-02T00:00:00Z",
                             "title": "Tooltips", "format_version": 1, "document": doc}))
    discard = page.locator(".toolbar button:text-is('Discard')")
    if discard.count():                   # an earlier step left the dashboard changed
        discard.click()
        discard.wait_for(state="detached")
    page.click(".brand")
    page.wait_for_selector("text=Dashboards · PRS")
    page.set_input_files(".file-button input", str(f))
    page.wait_for_url(lambda u: "/dashboards/" in u)
    p95 = page.locator(".widget th .tip-trigger:text-is('P95')")
    p95.wait_for(timeout=180_000)
    found = []
    tip = page.get_by_role("tooltip")
    p95.hover()
    try:
        tip.wait_for(timeout=3000)
        if "95th percentile" not in tip.inner_text():
            found.append(f"tooltip: P95's reads {tip.inner_text()!r}")
        page.screenshot(path=str(out / "11-tooltip.png"))
        page.keyboard.press("Escape")
        tip.wait_for(state="detached", timeout=3000)
    except Exception as e:
        found.append(f"tooltip: P95's on hover: {e}".splitlines()[0])
    page.mouse.move(5, 5)
    p95.focus()
    page.keyboard.press("Tab")
    try:
        tip.wait_for(timeout=3000)
        if "Readings the figures rest on" not in tip.inner_text():
            found.append(f"tooltip: Tab to Readings shows {tip.inner_text()!r}")
    except Exception:
        found.append("tooltip: Tab to Readings shows no tooltip")
    page.keyboard.press("Escape")
    return found


def calendar(page, out):
    """From and To's calendars: each opens on the day and time its field names, a day clicked and a
    time typed write YYYY-MM-DDTHH:MM into the field, Escape closes only the calendar, and the range
    applied is the one picked. The time picker's own dialog stays open throughout."""
    found = []
    page.click(".toolbar .range-button")
    picker = page.get_by_role("dialog", name="Time range")
    fields = {}
    for n, edge in ((1, "From"), (2, "To")):
        text_field = page.locator(f".time-picker .custom label:nth-child({n}) input")
        text = text_field.input_value()
        page.get_by_role("button", name=f"Pick {edge} date and time").click()
        cal = page.get_by_role("dialog", name=f"{edge} date and time")
        cal.wait_for()
        day = cal.locator(".calendar-cell[data-selected]")
        hour = cal.locator("[role=spinbutton][data-type=hour]")
        if re.match(r"\d{4}-\d{2}-\d{2}", text) and (not day.count() or day.inner_text() != str(int(text[8:10]))):
            found.append(f"calendar: {edge}'s opened on day {day.all_inner_texts()} for {text!r}")
        if not hour.count() or not hour.inner_text().isdigit():
            found.append(f"calendar: {edge}'s time has no hour for {text!r}")
        fields[edge] = f"{DAY}T{'09:15' if n == 1 else '11:45'}"
        cal.locator(".calendar-cell:not([data-outside-month])").filter(has_text=re.compile(rf"^{int(DAY[8:])}$")).click()
        hour.click()
        page.keyboard.type(fields[edge][11:13] + fields[edge][14:16])
        if n == 1:
            page.screenshot(path=str(out / "10-calendar.png"))
        written = text_field.input_value()
        if written != fields[edge]:
            found.append(f"calendar: picking {fields[edge]} in {edge} wrote {written!r}")
        page.keyboard.press("Escape")
        cal.wait_for(state="detached")
        if not picker.is_visible():
            found.append(f"calendar: Escape in {edge}'s calendar closed the time picker too")
            return found
    page.click(".time-picker .custom > button:text-is('Apply')")
    shown = page.inner_text(".toolbar .range-button")
    if shown != f"{fields['From'].replace('T', ' ')} to {fields['To'].replace('T', ' ')}":
        found.append(f"calendar: the range applied reads {shown!r}")
    return found


def folds(page, out):
    """The category tree's headings fold and unfold (design/frontend-aria.md phase 9): the root, Supply,
    opens with its branches shown, Enter on its heading hides them and says so, Enter again shows them,
    and a click on a folded branch, Production, opens it and shows its own."""
    found = []
    tree = page.locator(".category-tree")
    root = tree.locator(".fold-trigger:has-text('Supply')").first
    branch = tree.locator(".fold-trigger:has-text('Production')").first
    if root.get_attribute("aria-expanded") != "true" or not branch.is_visible():
        found.append("folds: Supply doesn't start open with its branches shown")
    root.focus()
    page.keyboard.press("Enter")
    if root.get_attribute("aria-expanded") != "false" or branch.is_visible():
        found.append("folds: Enter on Supply didn't fold it")
    page.keyboard.press("Enter")
    if root.get_attribute("aria-expanded") != "true" or not branch.is_visible():
        found.append("folds: Enter again didn't unfold Supply")
    if branch.get_attribute("aria-expanded") != "false":
        found.append("folds: Production doesn't start folded")
    branch.click()
    under = tree.locator(".fold:has(> .fold-heading .fold-trigger:has-text('Production')) > .fold-panel .fold-trigger")
    if branch.get_attribute("aria-expanded") != "true" or not under.first.is_visible():
        found.append("folds: a click didn't open Production")
    page.screenshot(path=str(out / "5b-folds.png"))
    return found


def add_widget(page, kind):
    """Add a widget of `kind` to the dashboard in edit mode; the new one is the last."""
    page.click(".toolbar button:has-text('Add a widget')")
    page.locator(f"[role=menuitem][data-key='{kind}']").click()
    return page.locator(".widget").last


def controls(page, out):
    """The React Aria controls (design/frontend-aria.md), by keyboard: on a new blank dashboard, a
    Stat's node picker offers matches as you type, Escape closes the list and clears the field, and
    the arrow keys and Enter pick one; the range and the silent meters open from the keyboard, close
    on Escape with focus back on their button, and the range on a click outside; leaving a changed
    dashboard and deleting one ask first, in a dialog that Escape or Cancel answers no; the arrow keys
    change the channel a click fills and move along the Activity Bar; a select opens on Enter, picks with
    the arrow keys and Enter, and Escape leaves it as it was; a Readings widget's quantities filter as you
    type, check by keyboard, stop at 8, and Escape clears the filter, not the choice; a Section's levels
    step by the arrow keys and +, and come back into 1..12; Import opens the file chooser."""
    found = []
    discard = page.locator(".toolbar button:text-is('Discard')")
    if discard.count():                   # an earlier step left the dashboard changed
        discard.click()
        discard.wait_for(state="detached")
    page.click(".brand")
    page.click("text=New blank dashboard")
    page.wait_for_selector(".toolbar")
    if page.locator(".toolbar button:text-is('Edit')").count():
        page.click(".toolbar button:text-is('Edit')")
    # Add a widget is a menu: arrow keys move through it, Escape closes it with focus back on its button
    page.focus(".toolbar button:has-text('Add a widget')")
    page.keyboard.press("Enter")
    menu = page.get_by_role("menu")
    menu.wait_for()
    page.keyboard.press("ArrowDown")
    page.screenshot(path=str(out / "9a-add-widget.png"))
    page.keyboard.press("Escape")
    menu.wait_for(state="detached")
    try:
        page.wait_for_function("() => document.activeElement?.textContent?.startsWith('Add a widget')", timeout=2000)
    except Exception:
        found.append("Add a widget: focus didn't return to its button after Escape")
    stat = add_widget(page, "stat")
    stat.locator("header button:text-is('Settings')").click()
    box = stat.get_by_role("combobox", name="Find a node")
    box.fill("LVMDB_A")
    page.wait_for_selector("[role=listbox] [role=option]:has-text('LVMDB_A5')")
    box.press("Escape")
    page.wait_for_selector("[role=listbox]", state="detached")
    if box.input_value():
        found.append(f"node picker: Escape left {box.input_value()!r} in the field")
    box.fill("LVMDB_A5")
    page.wait_for_selector("[role=listbox] [role=option]:has-text('LVMDB_A5')")
    box.press("ArrowDown")
    box.press("Enter")
    page.wait_for_selector("[role=listbox]", state="detached")
    if not stat.locator(".field b:text-is('LVMDB_A5')").count():
        found.append("node picker: Enter didn't pick LVMDB_A5")
    if box.input_value():
        found.append(f"node picker: the field kept {box.input_value()!r} after a pick")
    page.screenshot(path=str(out / "9-controls.png"))
    # a select: Enter opens its list on the current choice, ArrowDown and Enter pick the next, focus
    # back on its button; Escape closes it unchanged
    line = stat.locator(".field:has-text('Line') .select-button")
    line.focus()
    page.keyboard.press("Enter")
    options = page.get_by_role("listbox")
    options.wait_for()
    page.screenshot(path=str(out / "9d-select.png"))
    page.keyboard.press("ArrowDown")
    page.keyboard.press("Enter")
    options.wait_for(state="detached")
    if line.inner_text().split("\n")[0] != "None":
        found.append(f"select: ArrowDown and Enter left the line at {line.inner_text()!r}, not None")
    try:
        page.wait_for_function("() => document.activeElement?.classList.contains('select-button')", timeout=2000)
    except Exception:
        found.append("select: focus didn't return to its button after a pick")
    page.keyboard.press("Enter")
    options.wait_for()
    page.keyboard.press("ArrowUp")
    page.keyboard.press("Escape")
    options.wait_for(state="detached")
    if line.inner_text().split("\n")[0] != "None":
        found.append("select: Escape changed the choice")

    # a multiple choice: the filter narrows the list, the arrow keys and Enter check an item while
    # typing, the cap of 8 disables the rest, and Escape clears the filter but never the choice
    readings = add_widget(page, "readings")
    readings.locator("header button:text-is('Settings')").click()
    pick = readings.get_by_role("listbox", name="Quantities")
    chosen = readings.locator(".multi-chosen")
    filt = readings.get_by_role("searchbox", name="Filter quantities")
    filt.fill("thd")
    texts = pick.get_by_role("option").all_inner_texts()
    if not texts or any("THD" not in t for t in texts):
        found.append(f"multiple choice: the filter 'thd' shows {texts[:4]}")
    filt.press("ArrowDown")
    filt.press("Enter")
    if not chosen.inner_text().startswith("2 of 8"):
        found.append(f"multiple choice: ArrowDown and Enter didn't check the first match ({chosen.inner_text()!r})")
    filt.press("Escape")
    if filt.input_value() or not chosen.inner_text().startswith("2 of 8"):
        found.append(f"multiple choice: Escape left {filt.input_value()!r} in the filter"
                     f" or changed the choice ({chosen.inner_text()!r})")
    for _ in range(6):
        pick.locator("[role=option][aria-selected=false]").first.click()
    open_ = pick.locator("[role=option][aria-selected=false]:not([aria-disabled=true])").count()
    if not chosen.inner_text().startswith("8 of 8") or open_:
        found.append(f"multiple choice: at 8 ({chosen.inner_text()!r}) {open_} unchecked items can still be checked")
    readings.scroll_into_view_if_needed()
    page.screenshot(path=str(out / "9e-multiple.png"))

    # a number: the arrow keys and + step it, a number past the range comes back to it on leaving
    section = add_widget(page, "section")
    section.locator("header button:text-is('Settings')").click()
    levels = section.get_by_role("textbox", name="Levels")
    start = int(levels.input_value())
    levels.press("ArrowUp")
    section.get_by_role("button", name="More levels").click()
    if levels.input_value() != str(start + 2):
        found.append(f"levels: ArrowUp and + from {start} gave {levels.input_value()!r}")
    levels.fill("99")
    levels.press("Tab")
    if levels.input_value() != "12":
        found.append(f"levels: 99 became {levels.input_value()!r}, not 12")
    section.scroll_into_view_if_needed()
    page.screenshot(path=str(out / "9f-levels.png"))
    page.click(".toolbar button:text-is('Done editing')")

    # the range and the silent meters: each opens a dialog that Escape closes, focus back on its button
    for button, dialog in ((".toolbar .range-button", "Time range"), (".bottombar .health.link", "Silent meters")):
        page.focus(button)
        page.keyboard.press("Enter")
        panel = page.get_by_role("dialog", name=dialog)
        panel.wait_for()
        if dialog == "Time range":
            page.screenshot(path=str(out / "9b-range.png"))
        page.keyboard.press("Escape")
        panel.wait_for(state="detached")
        try:            # React Aria restores focus a frame after the panel goes
            page.wait_for_function("s => document.activeElement === document.querySelector(s)",
                                   arg=button, timeout=2000)
        except Exception:
            where = page.evaluate("() => document.activeElement?.outerHTML.slice(0, 80)")
            found.append(f"{dialog}: focus didn't return to its button after Escape (it is on {where})")
    # and a click outside closes the range
    page.click(".toolbar .range-button")
    page.get_by_role("dialog", name="Time range").wait_for()
    page.mouse.click(800, 600)
    page.get_by_role("dialog", name="Time range").wait_for(state="detached")

    # the channel a click fills: radios, the arrow keys change it
    find = page.locator(".activity-bar button[aria-label='Find'][aria-checked=false]")
    if find.count():
        find.click()
    page.locator(".channel-target").get_by_role("radio", name="A", exact=True).focus()
    page.keyboard.press("ArrowRight")
    try:
        page.wait_for_selector(".channel-target .choice.on:text-is('B')", timeout=2000)
    except Exception:
        found.append("channel target: ArrowRight from A didn't choose B")
    page.keyboard.press("ArrowLeft")

    # leaving with unsaved changes asks first: Escape stays (focus on Stay), Leave goes
    leave = page.get_by_role("alertdialog", name="Leave without saving?")
    page.click(".brand")
    leave.wait_for()
    if page.evaluate("() => document.activeElement?.textContent") != "Stay":
        found.append("leave page: focus doesn't start on Stay")
    page.keyboard.press("Escape")
    leave.wait_for(state="detached")
    if not page.locator(".toolbar button:text-is('Discard')").count():
        found.append("leave page: Escape didn't stay on the changed dashboard")
    page.click(".brand")
    leave.get_by_role("button", name="Leave").click()
    page.wait_for_selector("text=New blank dashboard")

    # Import is a button that opens the file chooser
    with page.expect_file_chooser(timeout=5000) as chooser:
        page.get_by_role("button", name="Import…").click()
    if chooser.value.is_multiple():
        found.append("import: the file chooser takes several files")

    # deleting a dashboard asks first: Cancel keeps it, Delete removes it
    rows = page.locator(".list tr:has(a:text-is('New dashboard'))")
    rows.first.wait_for()
    n = rows.count()
    ask = page.get_by_role("alertdialog", name="Delete “New dashboard”?")
    rows.first.locator("button:text-is('Delete')").click()
    ask.wait_for()
    page.screenshot(path=str(out / "9c-confirm.png"))
    ask.get_by_role("button", name="Cancel").click()
    ask.wait_for(state="detached")
    if rows.count() != n:
        found.append("delete: Cancel removed the dashboard")
    rows.first.locator("button:text-is('Delete')").click()
    ask.get_by_role("button", name="Delete").click()
    ask.wait_for(state="detached")
    try:
        page.wait_for_function(
            "n => [...document.querySelectorAll('.list tr a')]"
            ".filter(a => a.textContent === 'New dashboard').length === n",
            arg=n - 1, timeout=10_000)
    except Exception:
        found.append("delete: the dashboard is still listed after Delete")

    # the Activity Bar: arrow keys move between views, Enter opens one and closes it again
    page.focus(".activity-bar button[aria-label='Find']")
    page.keyboard.press("ArrowDown")
    if page.evaluate("() => document.activeElement?.getAttribute('aria-label')") != "Categories":
        found.append("Activity Bar: ArrowDown from Find didn't move to Categories")
    page.keyboard.press("Enter")
    page.wait_for_selector(".activity-bar button[aria-label='Categories'][aria-checked=true]")
    page.keyboard.press("Enter")
    page.wait_for_selector(".activity-bar button[aria-label='Categories'][aria-checked=false]")
    if page.locator(".side-bar").count():
        found.append("Activity Bar: Enter on the open view didn't close the side bar")
    return found


def zoom(page, out):
    """Drag to zoom on a time chart (design/frontend.md decision 32), on a new blank dashboard over a day:
    a mouse drag across a Readings chart sets the range to the span, to the minute, with ↶ beside it and
    the dashboard changed; a second drag on a Compare chart zooms further; ↶ steps back one zoom at a
    time and goes when there is none left; a drag under 5 px, Escape during a drag, and a touch drag
    leave the range alone; a range chosen in the time picker forgets the zooms."""
    found = []
    discard = page.locator(".toolbar button:text-is('Discard')")
    if discard.count():
        discard.click()
        discard.wait_for(state="detached")
    page.click(".brand")
    page.click("text=New blank dashboard")
    page.wait_for_selector(".toolbar")
    page.click(".toolbar .range-button")
    page.fill(".time-picker .custom label:nth-child(1) input", f"{DAY}T00:00")
    page.fill(".time-picker .custom label:nth-child(2) input", f"{DAY}T23:00")
    page.click(".time-picker .custom > button:text-is('Apply')")
    if page.locator(".toolbar button:text-is('Edit')").count():
        page.click(".toolbar button:text-is('Edit')")
    for kind in ("readings", "compare"):
        w = add_widget(page, kind)
        w.locator("header button:text-is('Settings')").click()
        box = w.get_by_role("combobox", name="Find a node")
        box.fill(INFO_NODE)
        page.wait_for_selector(f"[role=listbox] [role=option]:has-text('{INFO_NODE}')")
        box.press("ArrowDown")
        box.press("Enter")
        w.locator("header button:text-is('Done')").click()
    page.click(".toolbar button:text-is('Done editing')")
    page.click(".toolbar button:text-is('Save')")
    page.wait_for_selector(".toolbar button:has-text('Saved')")
    readings = page.locator(".widget").nth(0).locator(".chart canvas").first
    compare = page.locator(".widget").nth(1).locator(".chart canvas").first
    readings.wait_for()
    compare.wait_for()
    page.wait_for_function("() => !document.querySelector('.loading')", timeout=120_000)
    rng = page.locator(".toolbar .range-button")
    unzoom = page.locator(".toolbar button.unzoom")
    day = rng.inner_text()

    def drag(canvas, a, b, escape=False):
        bb = canvas.bounding_box()
        y = bb["y"] + bb["height"] * 0.55
        page.mouse.move(bb["x"] + bb["width"] * a, y)
        page.mouse.down()
        page.mouse.move(bb["x"] + bb["width"] * (a + b) / 2, y, steps=4)
        page.mouse.move(bb["x"] + bb["width"] * b, y, steps=4)
        if escape:
            page.keyboard.press("Escape")
        page.mouse.up()

    def minutes(text):
        m = re.findall(r"(\d{4}-\d{2}-\d{2}) (\d{2}):(\d{2})", text)
        return [f"{d}T{h}:{mi}" for d, h, mi in m]

    bb = readings.bounding_box()
    x = bb["x"] + bb["width"] * 0.5
    page.mouse.move(x, bb["y"] + bb["height"] * 0.55)
    page.mouse.down()
    page.mouse.move(x + 3, bb["y"] + bb["height"] * 0.55, steps=2)
    page.mouse.up()
    drag(readings, 0.3, 0.6, escape=True)
    cdp = page.context.new_cdp_session(page)
    ty = bb["y"] + bb["height"] * 0.55
    touch = (("touchStart", 0.3), ("touchMove", 0.4), ("touchMove", 0.5), ("touchMove", 0.6), ("touchEnd", None))
    for kind, f in touch:
        points = [] if f is None else [{"x": bb["x"] + bb["width"] * f, "y": ty}]
        cdp.send("Input.dispatchTouchEvent", {"type": kind, "touchPoints": points})
    page.wait_for_timeout(500)
    if rng.inner_text() != day or unzoom.count():
        found.append(f"zoom: a click, Escape or a touch drag changed the range to {rng.inner_text()!r}")

    drag(readings, 0.3, 0.7)
    page.wait_for_function("d => document.querySelector('.toolbar .range-button')?.textContent !== d", arg=day)
    first = rng.inner_text()
    ends = minutes(first)
    if len(ends) != 2 or not (f"{DAY}T00:00" < ends[0] < ends[1] < f"{DAY}T23:00"):
        found.append(f"zoom: the drag gave {first!r}, not a span inside the day")
    if not unzoom.count():
        found.append("zoom: no ↶ after a zoom")
    if not page.locator(".toolbar button:text-is('Save')").is_enabled():
        found.append("zoom: the dashboard isn't marked changed")
    page.wait_for_function("() => !document.querySelector('.loading')", timeout=120_000)
    page.wait_for_timeout(800)
    page.screenshot(path=str(out / "14-zoom.png"))
    drag(compare, 0.4, 0.6)
    page.wait_for_function("d => document.querySelector('.toolbar .range-button')?.textContent !== d", arg=first)
    second = minutes(rng.inner_text())
    if len(second) != 2 or not (ends[0] <= second[0] < second[1] <= ends[1]):
        found.append(f"zoom: the Compare drag gave {rng.inner_text()!r}, not a span inside {first!r}")
    unzoom.click()
    if rng.inner_text() != first:
        found.append(f"zoom: ↶ went to {rng.inner_text()!r}, not {first!r}")
    unzoom.click()
    if rng.inner_text() != day or unzoom.count():
        found.append(f"zoom: the second ↶ went to {rng.inner_text()!r} or left ↶ shown")
    drag(readings, 0.3, 0.7)
    unzoom.wait_for()
    page.click(".toolbar .range-button")
    page.click(".time-picker .presets button:text-is('Last 24 hours')")
    if unzoom.count():
        found.append("zoom: ↶ still shown after a range from the time picker")
    page.click(".toolbar button:text-is('Discard')")
    page.wait_for_selector(".toolbar button:has-text('Saved')")
    return found


def full_screen(page, out):
    """One widget in full screen (design/frontend.md decision 31), on a new blank dashboard: ⤢ in edit
    mode opens it at ?widget= with the settings panel on the right, the grid and Add a widget gone; a
    title and a node set in the panel redraw the widget beside it; saved and reloaded it stays in full
    screen, viewing, with no panel until Edit; "← Dashboard" goes back to the grid, as does the
    browser's Back after ⤢ on hover; Remove in the panel closes it; at a 400 px screen the panel lies
    under the widget and the page doesn't scroll sideways."""
    found = []
    discard = page.locator(".toolbar button:text-is('Discard')")
    if discard.count():
        discard.click()
        discard.wait_for(state="detached")
    page.click(".brand")
    page.click("text=New blank dashboard")
    page.wait_for_selector(".toolbar")
    page.click(".toolbar .range-button")
    page.fill(".time-picker .custom label:nth-child(1) input", f"{DAY}T10:00")
    page.fill(".time-picker .custom label:nth-child(2) input", f"{DAY}T12:00")
    page.click(".time-picker .custom > button:text-is('Apply')")
    if page.locator(".toolbar button:text-is('Edit')").count():
        page.click(".toolbar button:text-is('Edit')")
    add_widget(page, "stat")
    add_widget(page, "readings")
    page.locator(".widget").first.locator("header button[aria-label='Full screen']").click()
    page.wait_for_url(lambda u: "widget=" in u)
    panel = page.get_by_role("complementary", name="Widget settings")
    panel.wait_for()
    if page.locator(".widget").count() != 1:
        found.append(f"full screen: {page.locator('.widget').count()} widgets drawn, not 1")
    if page.locator(".toolbar button:has-text('Add a widget')").count():
        found.append("full screen: Add a widget still in the toolbar")
    widget = page.locator(".full-widget .widget")
    wbox, pbox = widget.bounding_box(), panel.bounding_box()
    if pbox["x"] < wbox["x"] + wbox["width"]:
        found.append("full screen: the panel isn't on the widget's right")
    panel.get_by_label("Title", exact=True).fill("Full check")
    widget.locator("header .title:text-is('Full check')").wait_for()
    box = panel.get_by_role("combobox", name="Find a node")
    box.fill(INFO_NODE)
    page.wait_for_selector(f"[role=listbox] [role=option]:has-text('{INFO_NODE}')")
    box.press("ArrowDown")
    box.press("Enter")
    try:
        figure = "document.querySelector('.full-widget .stat-figure')?.textContent ?? ''"
        page.wait_for_function(f"() => /\\d/.test({figure})", timeout=60_000)
    except Exception:
        found.append("full screen: the widget didn't redraw with a figure for the node set in the panel")
    page.screenshot(path=str(out / "13-full-screen.png"))

    page.click(".toolbar button:text-is('Save')")
    page.wait_for_selector(".toolbar button:has-text('Saved')")
    page.reload()
    page.wait_for_selector(".full-widget .widget header .title:text-is('Full check')")
    if panel.count():
        found.append("full screen: the settings panel shown while viewing")
    page.click(".toolbar button:text-is('Edit')")
    panel.wait_for()
    page.click(".toolbar button:text-is('Done editing')")
    panel.wait_for(state="detached")
    page.click(".toolbar button.back")       # after a reload: replaces the entry, stays on the dashboard
    page.wait_for_selector(".canvas")
    if "widget=" in page.url or "/dashboards/" not in page.url:
        found.append(f"full screen: ← Dashboard went to {page.url}")
    if page.locator(".widget").count() != 2:
        found.append(f"full screen: the grid came back with {page.locator('.widget').count()} widgets, not 2")
    first = page.locator(".widget").first
    first.locator("header").hover()
    first.locator("header .hover-only button[aria-label='Full screen']").click()
    page.wait_for_selector(".full-widget")
    if panel.count():
        found.append("full screen: ⤢ while viewing opened the panel")
    page.go_back()
    page.wait_for_selector(".canvas")
    if "widget=" in page.url or "/dashboards/" not in page.url:
        found.append(f"full screen: the browser's Back went to {page.url}")

    page.click(".toolbar button:text-is('Edit')")
    page.locator(".widget").first.locator("header button[aria-label='Full screen']").click()
    panel.wait_for()
    page.set_viewport_size({"width": 400, "height": 900})
    if page.locator(".side-bar").count():        # on a phone it lies over the page
        page.click(".side-bar .close")
    page.wait_for_timeout(500)
    wbox, pbox = widget.bounding_box(), panel.bounding_box()
    if pbox["y"] < wbox["y"] + wbox["height"]:
        found.append("full screen: at 400 px the panel isn't under the widget")
    wide = page.evaluate("document.documentElement.scrollWidth")
    if wide > 400:
        found.append(f"full screen: at 400 px the page is {wide} px wide")
    panel.scroll_into_view_if_needed()
    page.screenshot(path=str(out / "13b-full-screen-phone.png"))
    page.set_viewport_size({"width": 1600, "height": 1000})
    panel.get_by_role("button", name="Remove the widget").click()
    page.wait_for_selector(".canvas")
    if "widget=" in page.url:
        found.append("full screen: still at ?widget= after Remove")
    if page.locator(".widget").count() != 1:
        found.append(f"full screen: {page.locator('.widget').count()} widgets after Remove, not 1")
    page.click(".toolbar button:text-is('Discard')")
    page.wait_for_selector(".toolbar button:has-text('Saved')")
    return found


def phone(page, out):
    """The controls at a 400 px phone screen: the range and its calendar, Add a widget, a select's list,
    the multiple choice and the Reference search each open inside the screen, and the page never
    scrolls sideways."""
    found = []
    width = 400
    page.set_viewport_size({"width": width, "height": 900})

    def fits(loc, what, shot=None):
        loc.wait_for()
        box = loc.bounding_box()
        if shot:
            page.screenshot(path=str(out / shot))
        left, right = box["x"], box["x"] + box["width"]
        if left < 0 or right > width + 0.5:
            found.append(f"phone: {what} spans x {left:.0f} to {right:.0f} on a {width} px screen")
        wide = page.evaluate("document.documentElement.scrollWidth")
        if wide > width:
            found.append(f"phone: with {what} open the page is {wide} px wide")

    page.click(".brand")
    page.click("text=New blank dashboard")
    page.wait_for_selector(".toolbar")
    page.click(".toolbar .range-button")
    fits(page.get_by_role("dialog", name="Time range"), "the time range", "12-phone-range.png")
    page.get_by_role("button", name="Pick From date and time").click()
    fits(page.get_by_role("dialog", name="From date and time"), "From's calendar", "12b-phone-calendar.png")
    page.keyboard.press("Escape")
    page.keyboard.press("Escape")
    page.get_by_role("dialog", name="Time range").wait_for(state="detached")
    if page.locator(".toolbar button:text-is('Edit')").count():
        page.click(".toolbar button:text-is('Edit')")
    page.click(".toolbar button:has-text('Add a widget')")
    fits(page.get_by_role("menu"), "Add a widget's menu", "12c-phone-menu.png")
    page.locator("[role=menuitem][data-key='readings']").click()
    widget = page.locator(".widget").last
    widget.locator("header button:text-is('Settings')").click()
    fits(widget.get_by_role("listbox", name="Quantities"), "the quantities' list", "12d-phone-settings.png")
    widget.locator(".select-button").first.click()
    fits(page.get_by_role("listbox").last, "a select's list", "12e-phone-select.png")
    page.keyboard.press("Escape")
    page.click(".activity-bar button[aria-label='Reference'][aria-checked=false]")
    page.fill(f"{REF} .ref-head input", "LVMDB")
    fits(page.locator(f"{REF} [role=listbox]"), "Reference's matches", "12f-phone-reference.png")
    page.set_viewport_size({"width": 1600, "height": 1000})
    return found


def drive(page, url, email, temp, out, problems, nodes):
    def settle():
        page.wait_for_function("() => !document.querySelector('.loading')", timeout=180_000)
        page.wait_for_timeout(1500)       # chart animations

    def time_range(start, end):
        page.click(".toolbar .range-button")
        page.fill(".time-picker .custom label:nth-child(1) input", start)
        page.fill(".time-picker .custom label:nth-child(2) input", end)
        page.click(".time-picker .custom > button:text-is('Apply')")

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
    # resetting a password asks first; Escape answers no
    page.click(f"tr:has-text('{email.replace('web-check', 'web-check-user')}') button:text-is('Reset password')")
    ask = page.get_by_role("alertdialog", name="Reset")
    ask.wait_for()
    page.keyboard.press("Escape")
    ask.wait_for(state="detached")
    page.click(".brand")

    page.click(".topbar .tenant .select-button")
    page.click("[role=listbox] [role=option][data-key='3']")
    page.wait_for_selector("text=Dashboards · PRS")
    page.click("text=New from “Energy overview”")
    page.wait_for_selector(".toolbar")
    time_range("2026-10-20", "2026-10-22")
    settle()
    page.screenshot(path=str(out / "2-template.png"))

    # the side bar's Find: type groups, the utility and metered filters, a click sets channel A
    page.fill(".side-bar .find-filters input[placeholder='Find a node']", "LVMDB_A")
    page.click(".side-bar .find-filters .utilities button:has-text('Electricity')")
    page.click(".side-bar .find-filters .check:has-text('metered')")
    page.wait_for_selector(".side-bar .fold[data-expanded] .fold-trigger:has-text('MAIN_LV_BOARD')")
    page.click(".side-bar li:has-text('LVMDB_A5') .pick")
    page.wait_for_selector(".channel:has-text('LVMDB_A5')")
    # Find's text is a search field: Escape clears it, and the clear button too
    find_text = page.locator(".side-bar .find-filters input[placeholder='Find a node']")
    find_text.press("Escape")
    if find_text.input_value():
        problems.append(f"find: Escape left {find_text.input_value()!r} in the field")
    find_text.fill("LVMDB_A")
    page.click(".side-bar .find-filters .search-clear")
    if find_text.input_value():
        problems.append("find: the clear button left the field filled")
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
    stat = add_widget(page, "stat")
    stat.locator("header .select-button").click()
    page.click("[role=listbox] [role=option][data-key='A']")
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

    # the side bar: star a node, find it starred after a reload, and the category tree; the Activity
    # Bar's icon of the open view closes it, and opens it again
    page.fill(".side-bar .find-filters input[placeholder='Find a node']", "LVMDB_A5")
    page.click(".side-bar li:has-text('LVMDB_A5') .star")
    page.wait_for_selector(".side-bar li:has-text('LVMDB_A5') .star.on")
    page.reload()
    page.click(".activity-bar button[aria-label='Starred']")
    page.wait_for_selector(".side-bar li:has-text('LVMDB_A5') .star.on")
    page.wait_for_selector(".activity-bar button[aria-label='Starred'] .count:text-is('1')")
    page.click(".activity-bar button[aria-label='Categories']")
    page.wait_for_selector(".category-tree .fold-trigger:has-text('Production')")
    problems.extend(folds(page, out))
    page.click(".activity-bar button[aria-label='Categories']")
    page.wait_for_selector(".side-bar", state="detached")
    page.click(".activity-bar button[aria-label='Categories']")
    page.wait_for_selector(".category-tree .fold-trigger:has-text('Production')")
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
    found += reference(page, out, nodes)
    found += retired_and_inspect(page, out, nodes)
    found += units_and_compare(page, out, nodes)
    found += tooltips(page, out, nodes)
    found += calendar(page, out)
    found += sld_values(page, out, nodes)
    found += controls(page, out)
    found += full_screen(page, out)
    found += zoom(page, out)
    found += phone(page, out)
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
    nodes = node_ids(su, TOOLTIP_NODES + (INFO_NODE, METERS_NODE, UNMETERED, "LVMDP_SPINNING_1", "LVMDB_A1",
                                                  SLD_ROOT, "FACTORY_AB"))
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
