#!/usr/bin/env python3
"""Gather one month's figures for the executive energy report (design/executive-report-draft.md).

    uv run python tools/exec_report.py --tenant 3 --tz Asia/Jakarta --month 2026-10 -e .env.prod-ro
    uv run python tools/exec_report.py --tenant 3 --tz Asia/Jakarta --month 2026-10 --kvarh-price 1114.75

A working script: sections are added and changed as the report takes shape. It writes nothing: every
statement runs in a transaction that is rolled back (the solver and graph.sankey need temporary
tables, so default_transaction_read_only cannot be used). The connection comes
from the env file (-e, default .env), parsed, never sourced; every key is required, as in
tools/sld.py.

Writes to logs/<DB_LABEL>/exec_report_<month>/:
  report.md    the figures, section by section, with last month beside them where it means something
  report.json  the same, for whatever renders the brief later
  shifts.csv   energy per day x shift x category: the slot that production output per shift fills

Sections, in report order:
  1  supply         each source's energy (graph.sankey SUPPLY links), measured sources apart from
                    those the solver calculates (no meter of their own: the gas engine)
  2  bill check     grid kWh and cost by PLN rate code (daily_energy_cost_summary), plus the
                    excess kVArh of §3 at --kvarh-price: a rough estimate of the reactive charge
  3  reactive       grid kVArh against 0.62 x kWh (PF 0.85); IDR only with --kvarh-price
  4  contract       peak 15-min kVA and kW at the grid incomer against contract_kva; hours of use
  5  PV value       PV kWh x the grid's LWBP rate (PV produces in LWBP hours)
  6  where it goes  the category tree (graph.sankey CATEGORY links)
  7  per shift      graph.solve_flow per day and shift; each node's own value, weighted into its
                    categories by graph.sankey_nodes over the month, as graph.sankey does
  8  floor load     the 5th percentile of 15-min site power (grid + PV meters), and its share
  9  transformers   peak and P95 15-min kVA at each board's meter against its rated_kva
 10  trust          share of supply assigned to a category, graph.sankey_diagnostics
"""
import argparse
import calendar
import csv
import datetime as dt
import json
import pathlib
import sys
import zoneinfo
from collections import defaultdict

import psycopg
from psycopg.rows import dict_row

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
ENV_KEYS = ("LABEL", "HOST", "PORT", "NAME", "USER", "PASSWORD")
ENERGY, REACTIVE, KVA, KW = 124, 89, 530, 185      # graph.quantity_term ids
SHIFTS = ("SHIFT1", "SHIFT2", "SHIFT3")
PF_LIMIT_RATIO = 0.62                               # kVArh allowed per kWh at PF 0.85 (tan(acos 0.85))
IN_EFFECT = ("{a}.is_active AND {a}.effective_from <= %(as_of)s "
             "AND ({a}.effective_to IS NULL OR {a}.effective_to >= %(as_of)s)")


def eff(alias):
    return IN_EFFECT.format(a=alias)


def load_env(path):
    if not path.is_file():
        sys.exit(f"exec_report.py: {path} not found. Copy .env.example and fill it in.")
    vals = {}
    for raw in path.read_text().splitlines():
        if "=" in raw and not raw.lstrip().startswith("#"):
            k, v = raw.split("=", 1)
            vals[k.strip()] = v.strip().strip("\r").strip('"').strip("'")
    conn = {}
    for k in ENV_KEYS:
        if not vals.get(f"DB_{k}"):
            sys.exit(f"exec_report.py: {path} is missing DB_{k}. See .env.example.")
        conn[k] = vals[f"DB_{k}"]
    conn["SSLMODE"] = vals.get("DB_SSLMODE")     # optional, as for tools/sld.py's psql
    return conn


def connect(c):
    kw = dict(host=c["HOST"], port=c["PORT"], dbname=c["NAME"], user=c["USER"], password=c["PASSWORD"],
              connect_timeout=5, options="-c statement_timeout=120000",
              row_factory=dict_row, autocommit=True)
    if c["SSLMODE"]:
        kw["sslmode"] = c["SSLMODE"]
    return psycopg.connect(**kw)


def q(conn, sql, params=None):
    with conn.transaction(force_rollback=True), conn.cursor() as cur:
        cur.execute(sql, params or {})
        return cur.fetchall() if cur.description else []


def f(x):
    return None if x is None else float(x)


def utc_window(start, end, tz):
    """Site days start..end (inclusive) as naive UTC bounds [s, e), the way telemetry stores time
    (plant/timewin.py). daily_energy_cost_summary is already in site days; the 15-minute data is not."""
    s = dt.datetime.combine(start, dt.time(), tz).astimezone(dt.UTC).replace(tzinfo=None)
    e = dt.datetime.combine(end + dt.timedelta(days=1), dt.time(), tz).astimezone(dt.UTC).replace(tzinfo=None)
    return s, e


def site(ts_utc, tz):
    return ts_utc.replace(tzinfo=dt.UTC).astimezone(tz).replace(tzinfo=None)


def month_bounds(month):
    y, m = (int(p) for p in month.split("-"))
    start = dt.date(y, m, 1)
    end = dt.date(y, m, calendar.monthrange(y, m)[1])
    prev_end = start - dt.timedelta(days=1)
    return start, end, prev_end.replace(day=1), prev_end


# ---------------------------------------------------------------------------
# the plant's fixed points

def plant(conn, t, as_of):
    p = {"tenant": t, "as_of": as_of}
    grid = q(conn, f"""
        SELECT n.node_code, (n.attrs->>'contract_kva')::numeric AS contract_kva, m.device_id
        FROM graph.node n JOIN graph.measurement m ON m.node_id = n.id AND m.quantity_id = {ENERGY}
        WHERE n.tenant_id = %(tenant)s AND n.node_type = 'GRID_INCOMER' AND {eff('n')} AND {eff('m')}""", p)
    if len(grid) != 1:
        sys.exit(f"exec_report.py: expected one metered GRID_INCOMER, found {len(grid)}; extend the script")
    sources = q(conn, f"""
        SELECT n.node_code, n.node_name, n.node_type, m.device_id
        FROM graph.node n LEFT JOIN graph.measurement m
          ON m.node_id = n.id AND m.quantity_id = {ENERGY} AND {eff('m')}
        WHERE n.tenant_id = %(tenant)s AND n.node_class = 'SOURCE' AND {eff('n')}
          AND n.node_type IN ('GRID_INCOMER', 'PV_PLANT', 'GAS_ENGINE')
        ORDER BY n.node_type, n.node_code""", p)
    # each rated board's meter: on the board, or on its feeder from a non-source; full-weight devices
    # only (LVMDB_A4's PV x 1/3 row is not the transformer)
    boards = q(conn, f"""
        SELECT b.node_code, (b.attrs->>'rated_kva')::numeric AS rated_kva, m.device_id,
               CASE WHEN m.node_id IS NOT NULL THEN 'node' ELSE 'feeder' END AS meter_on
        FROM graph.node b
        JOIN graph.measurement m ON m.quantity_id = {ENERGY} AND m.multiplier = 1 AND {eff('m')}
         AND (m.node_id = b.id OR m.edge_id IN (
               SELECT e.id FROM graph.edge e JOIN graph.node s ON s.id = e.from_node_id
               WHERE e.to_node_id = b.id AND s.node_class <> 'SOURCE' AND {eff('e')}))
        WHERE b.tenant_id = %(tenant)s AND b.attrs ? 'rated_kva' AND {eff('b')}
          AND m.device_id NOT IN (SELECT m2.device_id FROM graph.measurement m2 JOIN graph.node s2
                                  ON s2.id = m2.node_id AND s2.node_class = 'SOURCE')
        ORDER BY b.node_code""", p)
    return {"grid": grid[0], "sources": sources, "boards": boards}


# ---------------------------------------------------------------------------
# 2-4: the grid bill, reactive energy, contract and peak

def grid_bill(conn, t, dev, start, end):
    p = {"tenant": t, "dev": dev, "start": start, "end": end}
    rates = q(conn, """
        SELECT COALESCE(rate_code, '(none)') AS rate_code, max(rate_per_unit) AS rate,
               sum(total_consumption) AS kwh, sum(total_cost) AS idr
        FROM daily_energy_cost_summary
        WHERE tenant_id = %(tenant)s AND device_id = %(dev)s AND quantity_id = 124
          AND grouping_type = 'SHIFT_RATE' AND daily_bucket >= %(start)s AND daily_bucket <= %(end)s
        GROUP BY 1 ORDER BY 1""", p)
    kvarh = q(conn, """
        SELECT sum(total_consumption) AS kvarh, count(DISTINCT daily_bucket) AS days
        FROM daily_energy_cost_summary
        WHERE tenant_id = %(tenant)s AND device_id = %(dev)s AND quantity_id = 89
          AND grouping_type = 'SHIFT_RATE' AND daily_bucket >= %(start)s AND daily_bucket <= %(end)s""", p)[0]
    days = q(conn, """
        SELECT count(DISTINCT daily_bucket) AS days FROM daily_energy_cost_summary
        WHERE tenant_id = %(tenant)s AND device_id = %(dev)s AND quantity_id = 124
          AND grouping_type = 'SHIFT_RATE' AND daily_bucket >= %(start)s AND daily_bucket <= %(end)s""", p)[0]
    kwh = sum(f(r["kwh"]) or 0 for r in rates)
    return {
        "by_rate": [{"rate_code": r["rate_code"], "rate": f(r["rate"]), "kwh": f(r["kwh"]), "idr": f(r["idr"])}
                    for r in rates],
        "kwh": kwh, "idr": sum(f(r["idr"]) or 0 for r in rates),
        "days_with_data": days["days"], "days_in_month": (end - start).days + 1,
        "kvarh": f(kvarh["kvarh"]),
    }


def reactive(bill, kvarh_price):
    kwh, kvarh = bill["kwh"], bill["kvarh"]
    if not kwh or kvarh is None:
        return None
    ratio = kvarh / kwh
    excess = max(0.0, kvarh - PF_LIMIT_RATIO * kwh)
    return {"kvarh": kvarh, "kwh": kwh, "kvarh_per_kwh": ratio, "pf": 1 / (1 + ratio ** 2) ** 0.5,
            "allowance_kvarh": PF_LIMIT_RATIO * kwh, "excess_kvarh": excess,
            "kvarh_price": kvarh_price, "excess_idr": excess * kvarh_price if kvarh_price else None}


def peak(conn, t, dev, uw, tz, contract_kva, grid_kwh):
    p = {"tenant": t, "dev": dev, "start": uw[0], "end": uw[1]}
    out = {}
    for qid, key in ((KVA, "kva"), (KW, "kw")):
        r = q(conn, f"""
            WITH b AS (
                SELECT bucket, aggregated_value AS v FROM telemetry_15min_agg
                WHERE tenant_id = %(tenant)s AND device_id = %(dev)s AND quantity_id = {qid}
                  AND bucket >= %(start)s AND bucket < %(end)s AND aggregated_value <> 'NaN'::numeric)
            SELECT b.bucket, b.v, s.p95, s.n
            FROM b, (SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY v) AS p95, count(*) AS n FROM b) s
            ORDER BY b.v DESC LIMIT 1""", p)
        out[key] = ({"max": f(r[0]["v"]), "at": site(r[0]["bucket"], tz).isoformat(), "p95": f(r[0]["p95"]),
                     "buckets": r[0]["n"]} if r else None)
    out["contract_kva"] = f(contract_kva)
    if out["kva"] and contract_kva:
        out["peak_of_contract"] = out["kva"]["max"] / float(contract_kva)
    out["hours_of_use"] = grid_kwh / float(contract_kva) if contract_kva else None   # jam nyala
    return out


# ---------------------------------------------------------------------------
# 5-7: supply and where it goes, from graph.sankey

def sankey(conn, t, start, end):
    rows = q(conn, """SELECT source, target, value, link_kind
                      FROM graph.sankey(%(t)s, %(s)s, %(e)s, NULL, 124, 'FUNCTIONAL', FALSE)""",
             {"t": t, "s": start, "e": end})
    supply = {r["source"]: f(r["value"]) for r in rows if r["link_kind"] == "SUPPLY"}
    cats = [(r["source"], r["target"], f(r["value"])) for r in rows if r["link_kind"] == "CATEGORY"]
    nodes = [(r["source"], r["target"], f(r["value"])) for r in rows if r["link_kind"] == "NODE"]
    return {"supply": supply, "supply_total": sum(supply.values()), "categories": cats, "nodes": nodes}


def diagnostics(conn, t, start, end):
    rows = q(conn, "SELECT node_code, kind, value, detail FROM graph.sankey_diagnostics(%(t)s, %(s)s, %(e)s)",
             {"t": t, "s": start, "e": end})
    return [{"node_code": r["node_code"], "kind": r["kind"], "value": f(r["value"]), "detail": r["detail"]}
            for r in rows]


def pv_value(sk, sources, bill):
    names = {s["node_name"] for s in sources if s["node_type"] == "PV_PLANT"}
    pv = {k: v for k, v in sk["supply"].items() if k in names}
    lwbp = [r["rate"] for r in bill["by_rate"] if r["rate_code"].startswith("LWBP") and r["rate"]]
    rate = max(lwbp) if lwbp else None
    total = sum(pv.values())
    return {"by_plant": pv, "kwh": total, "lwbp_rate": rate, "avoided_idr": total * rate if rate else None}


# ---------------------------------------------------------------------------
# 8: energy per day and shift, by category

OWN_SQL = """
    WITH nd AS (
        SELECT n.id, n.node_code AS code, n.node_class AS cls, n.val_src AS src, n.value AS val, n.out_deg,
               COALESCE((SELECT sum(g.value) FROM _ge g WHERE g.from_node_id = n.id), 0) AS out_sum
        FROM _gn n WHERE n.node_class NOT IN ('STORAGE', 'SINK'))
    SELECT id, code, cls, src, val,
           CASE WHEN cls = 'SOURCE' THEN
                    CASE WHEN src IN ('MEASURED', 'IN_EDGES') THEN val - out_sum ELSE 0 END
                WHEN out_deg = 0 THEN COALESCE(val, 0)
                WHEN src IN ('MEASURED', 'IN_EDGES') THEN val - out_sum
                ELSE 0 END AS own
    FROM nd"""      # graph.sankey_nodes' own-value rule (migration 054); keep in step with it


def category_tree(conn, t):
    rows = q(conn, """SELECT id, category_name, parent_id FROM graph.category
                      WHERE tenant_id = %(t)s AND taxonomy_code = 'FUNCTIONAL' AND is_active""", {"t": t})
    by_id = {r["id"]: r for r in rows}

    def chain(cid):
        out = []
        while cid is not None:
            out.append(by_id[cid]["category_name"])
            cid = by_id[cid]["parent_id"]
        return out[::-1]        # root first

    return {cid: chain(cid) for cid in by_id}


def per_shift(conn, t, start, end):
    """Solve each day x shift on its own; split each node's own value into its categories with the
    month's weights (graph.sankey_nodes), positive own values only, as graph.sankey draws them."""
    chains = category_tree(conn, t)
    weights = defaultdict(list)
    month_sources = {}
    for r in q(conn, """SELECT node_id, node_code, node_class, val_src, value, category_id, weight
                        FROM graph.sankey_nodes(%(t)s, %(s)s, %(e)s)""", {"t": t, "s": start, "e": end}):
        weights[r["node_id"]].append((r["category_id"], f(r["weight"])))
        if r["node_class"] == "SOURCE":
            month_sources[r["node_code"]] = {"val_src": r["val_src"], "kwh": f(r["value"]) or 0.0}
    changes = [r["change_date"] for r in q(conn, "SELECT change_date FROM graph.change_dates(%(t)s, %(s)s, %(e)s)",
                                           {"t": t, "s": start, "e": end})]
    rows = []
    day = start
    while day <= end:
        for shift in SHIFTS:
            # one transaction for both: solve_flow's _gn/_ge are dropped with it
            with conn.transaction(force_rollback=True), conn.cursor() as cur:
                cur.execute("""SELECT graph.solve_flow(%(t)s, 'ELECTRICITY', %(d)s::timestamp, %(d)s::timestamp,
                                                       124, FALSE, ARRAY[%(sh)s]::varchar[], %(d)s)""",
                            {"t": t, "d": day, "sh": shift})
                cur.execute(OWN_SQL)
                nodes = cur.fetchall()
            # a measured source adds up exactly over windows; a solved one (the gas engine, no meter of its
            # own) does not: each window keeps only its positive gap, so the windows sum to more than the month
            measured = sum(f(n["val"]) or 0 for n in nodes if n["cls"] == "SOURCE" and n["src"] == "MEASURED")
            solved = {n["code"]: f(n["val"]) or 0.0 for n in nodes if n["cls"] == "SOURCE" and n["src"] != "MEASURED"}
            lvl1, lvl2, negative = defaultdict(float), defaultdict(float), 0.0
            for n in nodes:
                own = f(n["own"]) or 0.0
                if own < 0:
                    negative += own
                    continue
                if own == 0:
                    continue
                for cid, w in weights.get(n["id"], [(None, 1.0)]):
                    path = chains.get(cid, []) if cid is not None else []
                    l1 = path[1] if len(path) > 1 else "Unassigned"
                    l2 = path[2] if len(path) > 2 else l1
                    lvl1[l1] += own * w
                    lvl2[f"{l1} / {l2}"] += own * w
            rows.append({"day": day.isoformat(), "weekday": day.strftime("%a"), "shift": shift,
                         "measured_supply": measured, "solved_sources": solved,
                         "supply": measured + sum(solved.values()), "negative_residual": negative, "level1": dict(lvl1),
                         "level2": dict(lvl2)})
        day += dt.timedelta(days=1)
    return {"rows": rows, "change_dates": [d.isoformat() for d in changes], "month_sources": month_sources}


def shift_summary(ps):
    by_shift = defaultdict(lambda: defaultdict(float))
    by_day = defaultdict(lambda: defaultdict(float))
    for r in ps["rows"]:
        for agg in (by_shift[r["shift"]], by_day[(r["day"], r["weekday"])]):
            agg["supply"] += r["supply"]
            agg["measured"] += r["measured_supply"]
            agg["solved"] += sum(r["solved_sources"].values())
        for k, v in r["level1"].items():
            by_shift[r["shift"]][k] += v
            by_day[(r["day"], r["weekday"])][k] += v
    return by_shift, by_day


def write_shifts_csv(ps, path):
    l2 = sorted({k for r in ps["rows"] for k in r["level2"]})
    solved = sorted({k for r in ps["rows"] for k in r["solved_sources"]})
    with path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["day", "weekday", "shift", "measured_supply_kwh", *(f"{k.lower()}_solved_kwh" for k in solved),
                    "negative_residual_kwh", *l2])
        for r in ps["rows"]:
            w.writerow([r["day"], r["weekday"], r["shift"], round(r["measured_supply"], 1),
                        *(round(r["solved_sources"].get(k, 0.0), 1) for k in solved), round(r["negative_residual"], 1),
                        *(round(r["level2"].get(k, 0.0), 1) for k in l2)])


# ---------------------------------------------------------------------------
# 9-10: floor load, transformer loading

def floor_load(conn, t, devices, uw, tz, supply_kwh):
    """Site power per 15 minutes = the sum of every metered source's ACTIVE_POWER. Buckets where the
    grid meter is missing are left out. The gas engine has no meter of its own and is not in it."""
    r = q(conn, f"""
        WITH b AS (
            SELECT bucket, sum(aggregated_value) AS kw, bool_or(device_id = %(grid)s) AS has_grid
            FROM telemetry_15min_agg
            WHERE tenant_id = %(t)s AND device_id = ANY(%(devs)s) AND quantity_id = {KW}
              AND bucket >= %(s)s AND bucket < %(e)s AND aggregated_value <> 'NaN'::numeric
            GROUP BY bucket)
        SELECT count(*) AS n,
               percentile_cont(0.05) WITHIN GROUP (ORDER BY kw) AS p5,
               percentile_cont(0.50) WITHIN GROUP (ORDER BY kw) AS p50,
               percentile_cont(0.95) WITHIN GROUP (ORDER BY kw) AS p95,
               avg(kw) AS mean
        FROM b WHERE has_grid""",
          {"t": t, "devs": devices["all"], "grid": devices["grid"], "s": uw[0], "e": uw[1]})[0]
    by_dow = q(conn, f"""
        WITH b AS (
            SELECT bucket, sum(aggregated_value) AS kw, bool_or(device_id = %(grid)s) AS has_grid
            FROM telemetry_15min_agg
            WHERE tenant_id = %(t)s AND device_id = ANY(%(devs)s) AND quantity_id = {KW}
              AND bucket >= %(s)s AND bucket < %(e)s AND aggregated_value <> 'NaN'::numeric
            GROUP BY bucket)
        SELECT extract(isodow FROM (bucket AT TIME ZONE 'UTC') AT TIME ZONE %(tz)s)::int AS dow,
               avg(kw) AS mean_kw, min(kw) AS min_kw
        FROM b WHERE has_grid GROUP BY 1 ORDER BY 1""",
          {"t": t, "devs": devices["all"], "grid": devices["grid"], "s": uw[0], "e": uw[1], "tz": tz.key})
    hours = (uw[1] - uw[0]).total_seconds() / 3600
    p5 = f(r["p5"])
    return {"buckets": r["n"], "buckets_expected": round(hours * 4), "p5_kw": p5, "p50_kw": f(r["p50"]),
            "p95_kw": f(r["p95"]), "mean_kw": f(r["mean"]),
            "floor_kwh": p5 * hours if p5 is not None else None,
            "floor_share": (p5 * hours / supply_kwh) if p5 is not None and supply_kwh else None,
            "by_weekday": [{"dow": x["dow"], "mean_kw": f(x["mean_kw"]), "min_kw": f(x["min_kw"])} for x in by_dow]}


def transformers(conn, t, boards, uw):
    out = []
    for b in boards:
        r = q(conn, f"""
            SELECT max(aggregated_value) AS mx,
                   percentile_cont(0.95) WITHIN GROUP (ORDER BY aggregated_value) AS p95, count(*) AS n
            FROM telemetry_15min_agg
            WHERE tenant_id = %(t)s AND device_id = %(d)s AND quantity_id = {KVA}
              AND bucket >= %(s)s AND bucket < %(e)s AND aggregated_value <> 'NaN'::numeric""",
              {"t": t, "d": b["device_id"], "s": uw[0], "e": uw[1]})[0]
        rated = f(b["rated_kva"])
        mx = f(r["mx"])
        out.append({"board": b["node_code"], "device": b["device_id"], "meter_on": b["meter_on"], "rated_kva": rated,
                    "peak_kva": mx, "p95_kva": f(r["p95"]), "buckets": r["n"],
                    "peak_of_rated": mx / rated if mx and rated else None})
    return sorted(out, key=lambda x: -(x["peak_of_rated"] or -1))


# ---------------------------------------------------------------------------
# the markdown

def n0(x):
    return "—" if x is None else f"{x:,.0f}"


def pct(x, d=1):
    return "—" if x is None else f"{100 * x:.{d}f}%"


def delta(cur, prev):
    if cur is None or not prev:
        return "—"
    return f"{100 * (cur - prev) / prev:+.1f}%"


def section8(w, r, sk, ps):
    by_shift, by_day = shift_summary(ps)
    w("## 7. Energy per shift and day\n")
    if ps["change_dates"]:
        w(f"**The graph changed inside the month on {', '.join(ps['change_dates'])}**; each day is solved on its own "
          "network, but category weights are the month-end's.\n")
    l1 = sorted({k for x in by_shift.values() for k in x if k not in ("supply", "measured", "solved")})
    ms = ps["month_sources"]
    m_meas = sum(v["kwh"] for v in ms.values() if v["val_src"] == "MEASURED")
    m_solved = {k: v["kwh"] for k, v in ms.items() if v["val_src"] != "MEASURED"}
    sh_meas = sum(x["measured"] for x in by_shift.values())
    sh_solved = defaultdict(float)
    for row in ps["rows"]:
        for k, v in row["solved_sources"].items():
            sh_solved[k] += v
    solved_names = ", ".join(sorted(m_solved)) or "none"
    w(f"Supply is split into what meters read and what the solver has to calculate ({solved_names}: no meter "
      "of its own). Measured supply adds up exactly across shifts. A calculated source does not: in each window "
      "it gets whatever is left between its neighbours' meters, never less than zero, so meter noise that "
      "cancels over a month adds up over 93 shifts.\n")
    w(f"| shift | measured supply kWh | {solved_names} (calculated) | {' | '.join(l1)} |\n"
      f"|---|--:|--:|{'--:|' * len(l1)}")
    for sh in SHIFTS:
        x = by_shift[sh]
        w(f"| {sh} | {n0(x['measured'])} | {n0(x['solved'])} | {' | '.join(n0(x.get(k)) for k in l1)} |")
    w(f"| sum of shifts | {n0(sh_meas)} | {n0(sum(sh_solved.values()))} | "
      f"{' | '.join(n0(sum(x.get(k, 0) for x in by_shift.values())) for k in l1)} |")
    month_l1 = {t_: v for s_, t_, v in sk["categories"] if s_ == "Supply"}
    w(f"| month, one solve | {n0(m_meas)} | {n0(sum(m_solved.values()))} | "
      f"{' | '.join(n0(month_l1.get(k)) for k in l1)} |\n")
    for k, v in sorted(m_solved.items()):
        w(f"- **{k}: {n0(sh_solved.get(k))} kWh over the shifts against {n0(v)} kWh for the month** "
          f"({delta(sh_solved.get(k), v)}). Neither is a measurement: a meter on its output would make both exact, "
          "and give a figure to check the vendor's bill against.")
    w(f"- Measured supply: shifts {n0(sh_meas)}, month {n0(m_meas)} ({delta(sh_meas, m_meas)}).\n")

    month_l2 = {f"{s_} / {t_}": v for s_, t_, v in sk["categories"] if s_ != "Supply"}
    sh_l2 = defaultdict(float)
    for row in ps["rows"]:
        for k, v in row["level2"].items():
            sh_l2[k] += v
    w("Categories, sum of shifts against the month's single solve (largest differences first):\n")
    w("| category | shifts kWh | month kWh | diff kWh | diff |\n|---|--:|--:|--:|--:|")
    comp = []
    for k in l1:
        comp.append((k, sum(x.get(k, 0) for x in by_shift.values()), month_l1.get(k)))
    for k, v in sh_l2.items():
        if k in month_l2:
            comp.append((k, v, month_l2[k]))
    for k, a_, b_ in sorted(comp, key=lambda c_: -abs(c_[1] - (c_[2] or 0))):
        w(f"| {k} | {n0(a_)} | {n0(b_)} | {n0(a_ - (b_ or 0))} | {delta(a_, b_)} |")
    w("\nA category differs when a node's value is capped or split differently in short windows (negative "
      "residuals are not drawn, so a board that goes negative in some shifts and positive in others keeps only "
      "the positive shifts).\n")
    w("\nPer day (measured supply, kWh), lowest five and highest five:\n")
    days = sorted(by_day.items(), key=lambda kv: kv[1]["measured"])
    for (d, wd), v in days[:5]:
        w(f"- low  {d} {wd}: {n0(v['measured'])}  ({', '.join(f'{k} {n0(v.get(k))}' for k in l1)})")
    for (d, wd), v in days[-5:]:
        w(f"- high {d} {wd}: {n0(v['measured'])}  ({', '.join(f'{k} {n0(v.get(k))}' for k in l1)})")
    w("\nFull table by second-level category: `shifts.csv`.\n")


def render(r):
    L = []
    w = L.append
    m, pm = r["month"], r["prev_month"]
    w(f"# Executive energy report — figures for {m}\n")
    w(f"Tenant {r['tenant']}, database `{r['db_label']}`, generated {r['generated']}. "
      f"Compared with {pm}. Working output of `tools/exec_report.py`, not the brief.\n")

    sk, psk = r["sankey"], r["prev_sankey"]
    w("## 1. Supply\n")
    metered = {x["node_name"] for x in r["plant"]["sources"] if x["device_id"]}
    # a source with no SUPPLY link in one month (the gas engine at 0) still gets its row, so both columns add up
    sources = list(sk["supply"]) + [k for k in psk["supply"] if k not in sk["supply"]]
    groups = [("Measured (a meter of its own)", [k for k in sources if k in metered]),
              ("Unmeasured (calculated by the solver)", [k for k in sources if k not in metered])]
    w(f"| source | {m} kWh | share | {pm} kWh | change |\n|---|--:|--:|--:|--:|")
    for label, keys in groups:
        if not keys:
            continue
        w(f"| *{label}* | | | | |")
        for k in sorted(keys, key=lambda k_: (-sk["supply"].get(k_, 0), -psk["supply"].get(k_, 0))):
            v = sk["supply"].get(k, 0)
            w(f"| {k} | {n0(v)} | {pct(v / sk['supply_total'])} | {n0(psk['supply'].get(k, 0))} | "
              f"{delta(v, psk['supply'].get(k))} |")
        cur, prv = sum(sk["supply"].get(k, 0) for k in keys), sum(psk["supply"].get(k, 0) for k in keys)
        w(f"| subtotal | {n0(cur)} | {pct(cur / sk['supply_total'])} | {n0(prv)} | {delta(cur, prv)} |")
    w(f"| **total** | **{n0(sk['supply_total'])}** | | {n0(psk['supply_total'])} | "
      f"{delta(sk['supply_total'], psk['supply_total'])} |\n")
    unmetered = groups[1][1]
    if unmetered:
        w(f"{', '.join(unmetered)}: no meter on the output. The solver gives it what its neighbours' meters leave "
          "unexplained, never below zero, so any metering error around it lands in this figure (§7). "
          "A meter on its output would make it a measurement.\n")

    b, pb = r["bill"], r["prev_bill"]
    w("## 2. Grid bill check\n")
    w(f"Meter: device {r['plant']['grid']['device_id']} (`{r['plant']['grid']['node_code']}`), "
      f"{b['days_with_data']} of {b['days_in_month']} days with data. **Compare with the PLN invoice.**\n")
    w("| rate | IDR/kWh | kWh | IDR |\n|---|--:|--:|--:|")
    for x in b["by_rate"]:
        w(f"| {x['rate_code']} | {n0(x['rate'])} | {n0(x['kwh'])} | {n0(x['idr'])} |")
    avg = b["idr"] / b["kwh"] if b["kwh"] else None
    w(f"| **energy** | {n0(avg)} avg | **{n0(b['kwh'])}** | **{n0(b['idr'])}** |")
    rx, prx = r["reactive"], r["prev_reactive"]
    if rx:
        price = rx["kvarh_price"]
        w(f"| reactive, excess kVArh (rough estimate) | {n0(price) if price else '—'} | "
          f"{n0(rx['excess_kvarh'])} kVArh | {n0(rx['excess_idr']) if price else '—'} |")
        if price:
            w(f"| **energy + reactive** | | | **{n0(b['idr'] + rx['excess_idr'])}** |")
    w("")
    if rx:
        w("Reactive: a rough estimate based on the power factor and reactive energy measured at this meter "
          f"(kVArh above {PF_LIMIT_RATIO} × kWh, §3), not PLN's figure. "
          + ("" if rx["kvarh_price"] else "IDR needs `--kvarh-price` from the invoice. ")
          + "Energy and reactive charges only: no demand charge, taxes or fees.\n")
    prev = f"{pm}: {n0(pb['kwh'])} kWh, Rp {n0(pb['idr'])} ({delta(b['idr'], pb['idr'])})"
    if rx and prx and rx["kvarh_price"]:
        prev += (f"; with reactive (rough estimate) Rp {n0(pb['idr'] + prx['excess_idr'])} "
                 f"({delta(b['idr'] + rx['excess_idr'], pb['idr'] + prx['excess_idr'])})")
    w(prev + ".\n")

    w("## 3. Reactive energy (PF penalty exposure)\n")
    if rx:
        w(f"- {n0(rx['kvarh'])} kVArh against {n0(rx['kwh'])} kWh: {rx['kvarh_per_kwh']:.3f} kVArh/kWh, "
          f"average PF **{rx['pf']:.3f}** (PLN's limit 0.85 = {PF_LIMIT_RATIO} kVArh/kWh).")
        w(f"- Allowance {n0(rx['allowance_kvarh'])} kVArh; **excess {n0(rx['excess_kvarh'])} kVArh**.")
        w(f"- At Rp {n0(rx['kvarh_price'])}/kVArh: Rp {n0(rx['excess_idr'])}." if rx["kvarh_price"]
          else "- IDR: pass `--kvarh-price` from the invoice.")
        if prx:
            w(f"- {pm}: PF {prx['pf']:.3f}, excess {n0(prx['excess_kvarh'])} kVArh.")
    w("")

    pk = r["peak"]
    w("## 4. Contract and peak demand\n")
    if pk.get("kva"):
        w(f"- Peak 15-min apparent power **{n0(pk['kva']['max'])} kVA** at {pk['kva']['at']}, "
          f"{pct(pk.get('peak_of_contract'))} of the {n0(pk['contract_kva'])} kVA contract; "
          f"P95 {n0(pk['kva']['p95'])} kVA.")
    if pk.get("kw"):
        w(f"- Peak active power {n0(pk['kw']['max'])} kW at {pk['kw']['at']}; P95 {n0(pk['kw']['p95'])} kW.")
    w(f"- Hours of use (jam nyala): {n0(pk['hours_of_use'])} h (grid kWh / contract kVA).\n")

    pv = r["pv"]
    w("## 5. PV value\n")
    w(f"- PV {n0(pv['kwh'])} kWh ({pct(pv['kwh'] / sk['supply_total'])} of supply). At the grid's LWBP rate "
      f"(Rp {n0(pv['lwbp_rate'])}) that is **Rp {n0(pv['avoided_idr'])}** of grid energy not bought.")
    w("- Before any saving is claimed: what does the PV cost per kWh (PPA/lease, or owned)? See draft §6.3.\n")

    w("## 6. Where the energy goes\n")
    prev_cats = {(s, t_): v for s, t_, v in psk["categories"]}
    w(f"| from | to | {m} kWh | share of supply | {pm} kWh | change |\n|---|---|--:|--:|--:|--:|")
    for s, t_, v in sorted(sk["categories"], key=lambda x: (x[0] != "Supply", x[0], -x[2])):
        w(f"| {s} | {t_} | {n0(v)} | {pct(v / sk['supply_total'])} | {n0(prev_cats.get((s, t_)))} | "
          f"{delta(v, prev_cats.get((s, t_)))} |")
    if sk["nodes"]:
        w("\nBoard residuals drawn as nodes (a board's own value under a category, not a sub-category):\n")
        for s, t_, v in sorted(sk["nodes"], key=lambda x: -x[2]):
            w(f"- {s} → {t_}: {n0(v)} kWh")
    w("")

    ps = r["per_shift"]
    if ps["rows"]:
        section8(w, r, sk, ps)
    else:
        w("## 7. Energy per shift and day\n\nSkipped (`--no-shifts`).\n")

    fl = r["floor"]
    w("## 8. Floor load\n")
    w(f"Site power = grid + PV meters, 15-min; {fl['buckets']} of {fl['buckets_expected']} buckets. The gas engine "
      "has no meter of its own and is left out.\n")
    w(f"- P5 **{n0(fl['p5_kw'])} kW**, median {n0(fl['p50_kw'])} kW, P95 {n0(fl['p95_kw'])} kW, "
      f"mean {n0(fl['mean_kw'])} kW.")
    w(f"- The P5 level held for the whole month is {n0(fl['floor_kwh'])} kWh, **{pct(fl['floor_share'])} of supply**: "
      "how flat the load is. In a plant running three shifts most of it is production, not waste; "
      "separating the two needs output per shift (or the utilities on the lowest days, §7).")
    dows = "Mon Tue Wed Thu Fri Sat Sun".split()
    w("- By weekday (mean / min kW): " + ", ".join(
        f"{dows[x['dow'] - 1]} {n0(x['mean_kw'])}/{n0(x['min_kw'])}" for x in fl["by_weekday"]) + "\n")

    w("## 9. Transformer loading\n")
    w("| board | meter | rated kVA | peak kVA | peak/rated | P95 kVA |\n|---|---|--:|--:|--:|--:|")
    for x in r["transformers"]:
        w(f"| {x['board']} | {x['device']} ({x['meter_on']}) | {n0(x['rated_kva'])} | {n0(x['peak_kva'])} | "
          f"{pct(x['peak_of_rated'], 0)} | {n0(x['p95_kva'])} |")
    w("\nA board with no peak had no reading in the month (LVMDB_TEXTURE is out of service since 2026-05-11, 050).")
    w("LVMDB_A4's meter (26) reads the board on two phases and the grid on the third (048), so its "
      "loading is approximate.\n")

    w("## 10. Trust\n")
    unassigned = next((v for s, t_, v in sk["categories"] if s == "Supply" and t_ == "Unassigned"), 0.0)
    w(f"- Assigned to a category: **{pct(1 - unassigned / sk['supply_total'])}** of supply; "
      f"Unassigned {n0(unassigned)} kWh.")
    kinds = defaultdict(list)
    for d in r["diagnostics"]:
        kinds[d["kind"]].append(d)
    for k, rows in sorted(kinds.items()):
        tot = sum(x["value"] or 0 for x in rows)
        w(f"- {k}: {len(rows)}" + (f", {n0(tot)} kWh" if tot else "") + " — "
          + "; ".join(f"{x['node_code']}" + (f" {n0(x['value'])}" if x["value"] else "") for x in rows[:12]))
    w("")
    return "\n".join(L)


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--tenant", type=int, required=True)
    ap.add_argument("--month", required=True, help="YYYY-MM, a finished month")
    ap.add_argument("--tz", required=True, help="the site's IANA zone, e.g. Asia/Jakarta (telemetry is UTC)")
    ap.add_argument("-e", "--env-file", default=".env")
    ap.add_argument("--kvarh-price", type=float, help="IDR per excess kVArh, from the PLN invoice")
    ap.add_argument("--no-shifts", action="store_true", help="skip the day x shift solves (about 15 s a month)")
    a = ap.parse_args()

    c = load_env(ROOT_DIR / a.env_file if not pathlib.Path(a.env_file).is_absolute() else pathlib.Path(a.env_file))
    print(f"target: {c['LABEL']} ({c['USER']}@{c['HOST']}:{c['PORT']}/{c['NAME']}), every transaction rolled back",
          file=sys.stderr)
    start, end, pstart, pend = month_bounds(a.month)
    tz = zoneinfo.ZoneInfo(a.tz)
    uw = utc_window(start, end, tz)
    if end >= dt.date.today():
        sys.exit(f"exec_report.py: {a.month} is not finished")

    with connect(c) as conn:
        pl = plant(conn, a.tenant, end)
        gdev = pl["grid"]["device_id"]
        sk, psk = sankey(conn, a.tenant, start, end), sankey(conn, a.tenant, pstart, pend)
        bill, pbill = grid_bill(conn, a.tenant, gdev, start, end), grid_bill(conn, a.tenant, gdev, pstart, pend)
        devs = {"grid": gdev, "all": [s["device_id"] for s in pl["sources"] if s["device_id"]]}
        r = {
            "tenant": a.tenant, "month": a.month, "prev_month": pstart.strftime("%Y-%m"), "db_label": c["LABEL"],
            "generated": dt.datetime.now().isoformat(timespec="seconds"), "plant": pl,
            "sankey": sk, "prev_sankey": psk, "bill": bill, "prev_bill": pbill,
            "reactive": reactive(bill, a.kvarh_price), "prev_reactive": reactive(pbill, a.kvarh_price),
            "peak": peak(conn, a.tenant, gdev, uw, tz, pl["grid"]["contract_kva"], bill["kwh"]),
            "pv": pv_value(sk, pl["sources"], bill),
            "floor": floor_load(conn, a.tenant, devs, uw, tz, sk["supply_total"]),
            "transformers": transformers(conn, a.tenant, pl["boards"], uw),
            "diagnostics": diagnostics(conn, a.tenant, start, end),
            "per_shift": {"rows": [], "change_dates": []} if a.no_shifts else per_shift(conn, a.tenant, start, end),
        }

    out = ROOT_DIR / "logs" / c["LABEL"] / f"exec_report_{a.month}"
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.md").write_text(render(r))
    (out / "report.json").write_text(json.dumps(r, indent=1, default=str))
    if r["per_shift"]["rows"]:
        write_shifts_csv(r["per_shift"], out / "shifts.csv")
    print(out)


if __name__ == "__main__":
    main()
