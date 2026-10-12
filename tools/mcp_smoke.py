#!/usr/bin/env python3
"""Call a running o-mcp server the way a client does, and check every answer.

    O_MCP_URL=http://127.0.0.1:8765/mcp O_MCP_TOKEN=... \\
      uv run python tools/mcp_smoke.py --window 2026-09-28 2026-10-04

Plain JSON-RPC over HTTP with the 2025-06-18 handshake, which is what most clients (Hermes among
them) speak; no SDK on this side, so what is checked is what goes over the wire. It initializes,
lists the tools (printing the size of tools/list, the cost every conversation pays), calls each tool
with tenant-3 arguments, and checks each structuredContent against the tool's outputSchema
strictly (tools/check_subgraph.py's rule: no field the schema does not list). Then a few calls that
must fail with isError and a message. --window is a stretch of days with telemetry; on dev, the
week tools/dev_refresh.sh --telemetry copied. Exits 1 if anything fails.
"""
import argparse
import copy
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jsonschema

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_subgraph import strict  # noqa: E402

PROTOCOL = "2025-06-18"


class Rpc:
    def __init__(self, url, token):
        self.url, self.token, self.n = url, token, 0

    def __call__(self, method, params=None):
        self.n += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}).encode()
        req = urllib.request.Request(self.url, data=body, method="POST", headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": PROTOCOL})
        t0 = time.monotonic()
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
        msg = json.loads(raw)
        if "error" in msg:
            raise RuntimeError(f"{method}: {msg['error']}")
        return msg["result"], len(raw), (time.monotonic() - t0) * 1000


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--window", nargs=2, metavar=("START", "END"), required=True,
                    help="days with telemetry, YYYY-MM-DD; END excluded")
    a = ap.parse_args()
    url, token = os.environ.get("O_MCP_URL"), os.environ.get("O_MCP_TOKEN")
    if not url or not token:
        sys.exit("mcp_smoke.py: set O_MCP_URL and O_MCP_TOKEN")
    start, end = a.window
    last_day = end   # as_of: the meters as they were at the end of the window
    rpc = Rpc(url, token)

    init, _, _ = rpc("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                    "clientInfo": {"name": "mcp_smoke", "version": "1"}})
    print(f"server {init['serverInfo']['name']} {init['serverInfo'].get('version', '')}, "
          f"protocol {init['protocolVersion']}")
    listed, size, _ = rpc("tools/list")
    tools = {t["name"]: t for t in listed["tools"]}
    print(f"tools/list: {len(tools)} tools, {size} bytes (about {size // 4} tokens)")
    for t in listed["tools"]:
        print(f"  {t['name']:18} {len(json.dumps(t)):6} bytes")

    ok = [
        ("plant_vocabulary", {"kind": "node_type", "code": "SUB_BOARD"}),
        ("plant_vocabulary", {"kind": "quantity"}),
        ("plant_vocabulary", {}),
        ("plant_find", {"text": "texture"}),
        ("plant_find", {"type": "SWITCHBOARD", "metered": False}),
        ("plant_section", {"root": "INCOMING_PLN", "depth": 2}),
        ("plant_section", {"root": "mc 9", "direction": "up", "depth": 6}),
        ("plant_section", {"root": "WTP1_RAN", "depth": 12, "utility": "WATER"}),
        ("node_meters", {"node": "LVMDB_A5", "as_of": last_day}),
        ("node_meters", {"node": "LVMDB_TEXTURE", "as_of": last_day}),
        ("node_meters", {"node": "WTP1_CLR", "as_of": last_day}),
        ("meter_readings", {"node": "LVMDB_A5", "quantities": ["ACTIVE_ENERGY_DELIVERED", "PF_TOTAL"],
                            "start": start, "end": end, "interval": "day", "as_of": last_day}),
        ("meter_readings", {"node": "LVMDB_A5", "quantities": ["THD_VOLTAGE_LN"], "start": start, "end": end,
                            "interval": "hour", "as_of": last_day}),
        ("node_value", {"nodes": ["INCOMING_PLN", "LVMDB_A5", "LVSDP_SP2_1"], "quantity": "ACTIVE_ENERGY_DELIVERED",
                        "start": start, "end": end, "as_of": last_day}),
        ("node_value", {"nodes": ["INCOMING_PLN", "LVSDP_SP2_1"], "quantity": "PF_TRUE", "start": start, "end": end,
                        "as_of": last_day}),
        ("node_value", {"nodes": ["INCOMING_PLN", "LVSDP_SP2_1"], "quantity": "THD_VOLTAGE_LN", "start": start,
                        "end": end, "as_of": last_day}),
        ("node_value", {"nodes": ["WTP1_CLR", "WTP1_RAN"], "quantity": "WATER_VOLUME", "start": start, "end": end,
                        "as_of": last_day}),
    ]
    must_fail = [
        ("plant_section", {"root": "LVMBD_A5"}),
        ("plant_find", {"class": "NOPE"}),
        ("node_value", {"nodes": ["LVMDB_A5"], "quantity": "PF_TOTAL", "start": start, "end": end}),
        ("meter_readings", {"node": "LVMDB_A5", "quantities": ["ACTIVE_ENERGY_DELIVERED"], "start": start,
                            "end": end, "interval": "15min", "as_of": last_day}),
        ("nope", {}),
    ]
    validators = {n: jsonschema.Draft202012Validator(strict(copy.deepcopy(t["outputSchema"])))
                  for n, t in tools.items() if t.get("outputSchema")}
    failed = 0
    for name, args in ok:
        res, size, ms = rpc("tools/call", {"name": name, "arguments": args})
        doc = res.get("structuredContent")
        errs = [] if doc is None else [e.message for e in validators[name].iter_errors(doc)]
        good = not res.get("isError") and doc is not None and not errs and \
            json.loads(res["content"][-1]["text"]) == doc
        failed += not good
        print(f"{'ok  ' if good else 'FAIL'} {name:16} {ms:7.0f} ms {size:7} bytes  {res['content'][0]['text'][:110]}")
        for e in errs[:5]:
            print(f"       {e}")
    for name, args in must_fail:
        res, _, ms = rpc("tools/call", {"name": name, "arguments": args})
        good = res.get("isError") is True and res["content"][0]["text"]
        failed += not good
        print(f"{'ok  ' if good else 'FAIL'} {name:16} {ms:7.0f} ms  refused: {res['content'][0]['text'][:110]}")
    try:
        urllib.request.urlopen(urllib.request.Request(url, data=b"{}", method="POST"), timeout=10)
        print("FAIL a request without the token was answered")
        failed += 1
    except urllib.error.HTTPError as e:
        print(f"{'ok  ' if e.code == 401 else 'FAIL'} no token: HTTP {e.code}")
        failed += e.code != 401
    print(f"{failed} failed" if failed else "all passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
