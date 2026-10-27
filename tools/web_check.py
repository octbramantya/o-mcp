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
channel's widgets follow; narrow to two hours so readings go to minutes and Now has readings; save,
reload and find it as saved; look at the bottom bar's data health; then at phone width.
"""
import argparse
import asyncio
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


def drive(page, url, email, temp, out, problems):
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

    page.click(".widget:has-text('Node finder') tr:has-text('LVMDB_A5')")
    page.wait_for_selector(".channel:has-text('LVMDB_A5')")
    time_range(f"{DAY}T10:00", f"{DAY}T12:00")
    settle()
    page.wait_for_selector("text=minute points")
    page.wait_for_selector(".widget:has-text('Now') td:has-text('PF_TOTAL')")
    page.screenshot(path=str(out / "3-minutes.png"))

    page.click("text=Save")
    page.wait_for_selector("button:has-text('Saved')")
    page.reload()
    page.wait_for_selector(".channel:has-text('LVMDB_A5')")
    settle()
    page.wait_for_selector(".bottombar :text('meters silent')")
    page.evaluate("document.querySelector('main').scrollTo(0, 99999)")
    page.screenshot(path=str(out / "4-lower.png"))
    page.set_viewport_size({"width": 400, "height": 900})
    page.wait_for_timeout(1500)
    wide = page.evaluate("document.documentElement.scrollWidth")
    page.screenshot(path=str(out / "5-phone.png"))
    return [f"widget error: {t}" for t in page.locator(".widget .error").all_inner_texts()] + \
        ([f"the page is {wide} px wide at a 400 px screen"] if wide > 400 else [])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--env-file", required=True)
    ap.add_argument("--url", default="http://127.0.0.1:5173/")
    ap.add_argument("--chromium", help="a Chromium or headless shell to use instead of Playwright's own")
    ap.add_argument("--out", default=str(ROOT / "logs" / "web-check"))
    a = ap.parse_args()
    cfg = config.load(a.env_file)
    if cfg.db_label != "dev":
        sys.exit(f"web_check: {a.env_file} targets {cfg.db_label}, not dev")
    raw = parse_env_file(a.env_file)
    su = dict(host=cfg.db_host, port=cfg.db_port, dbname=cfg.db_name, user=raw["DB_USER"],
              password=raw["DB_PASSWORD"], sslmode=cfg.db_sslmode)
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
            page.on("response", lambda r: r.status >= 400 and "/api/" in r.url
                    and problems.append(f"{r.status} {r.request.method} {r.url}"))
            try:
                problems += drive(page, a.url, email, temp, out, problems)
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
