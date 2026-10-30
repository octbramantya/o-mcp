# MCP tool catalogue

Every tool the server is expected to need, by layer, and how the model meets them. Written
2026-10-12 as a catalogue, not a spec: a tool gets a description, input schema and output format
in `design/mcp-tools.md` when it is drafted. Counts are from dev, which matched production on
2026-10-07.

## 1. The five proposed layers, assessed

The proposal: (1) node discovery, (2) quantity discovery, (3) fetching measurements,
(4) traversal, (5) analysis. All five are needed. Four changes:

**Traversal belongs with discovery, not after measurement.** Order the layers by what they
read, because that is also the order they can ship in: topology needs no telemetry, so layers
1 and 4 together are phase 1 (`mcp-server.md` §5) and can be used before any window question is
settled.

**Quantity discovery has two answers, and the tools must not merge them.**

| | what | for which nodes | how many |
|---|---|---|---|
| reported | what the attached meters send | the 97 metered nodes (103 devices) | 4 to 90 per device, median 56 (dev week 2026-09-27 to 10-04) |
| resolvable | what the solver can give for any node, measured or inferred | all 188 | 10 (`graph.quantity_rule`: 5 `SUM`, 4 `NONE`, 1 `INHERIT`) plus `PF_TRUE` |

83 nodes in effect have no meter on themselves or on any of their edges. Asked "what can I know about `PANEL_X`?", a tool that lists only device
quantities answers "nothing" for almost half the plant, though its energy is resolvable from its
neighbours. And a node that is metered for `THD_VOLTAGE_LN` is not a node whose THDv may be
averaged with its siblings. Two tools, two words: a *reading* comes from a meter, a *value* from
the solver with its `origin`.

**"The value at a timestamp" is the wrong primitive.** 8 of the 9 quantities in
`graph.measurement` are counters or encoded:

- An energy register at 14:00 is a lifetime total; what anyone wants is the consumption over a
  window. `quantity_term.reading` (`COUNTER` / `SAMPLE`) decides the aggregation, server-side.
- Schneider `PF_TOTAL` is quadrant-encoded on -2..2 (`mcp-tools.md`, gap 4). A raw value
  returned to the model will be averaged by the model.

So the reading tool takes a window and an interval. A point in time is a window of one bucket,
and the response says which bucket it used.

**Layer 5 is not optional, and it is what keeps layers 1–4 safe.** Every analysis the plant
needs combines nodes, and every naive composition of primitives is a known wrong answer here:

| what a model would do with primitives only | why it is wrong |
|---|---|
| sum the children's readings to explain a board | ignores residuals (unmetered load), dead branches and ambiguous splits (`graph-network-design.md` §5.5) |
| average power factor over a week | quadrant encoding; and PF over a window is `P / sqrt(P²+Q²)` of the energies, not a mean of samples (`PF_TRUE`) |
| combine THD percentages up a bus | what migration 040 removed from the solver |
| rank PF culprits by their own PF | the ranking is by kVArh contribution (§11.4) |
| walk ancestors by calling a section tool N times | slow, and loses the shallowest-path rule of `graph.ancestors` |

The rule that falls out: **a primitive answers about one node, one meter or one walk; anything
that combines nodes or applies physics across time is an analysis tool**, and the primitives'
descriptions say so ("for totals across nodes, use `energy_flow`").

## 2. The catalogue

Layer numbers below replace the proposal's: 0 vocabulary, 1 topology (discovery + traversal),
2 instruments, 3 values, 4 analysis.

### Layer 0 — vocabulary (no telemetry)

| tool | answers | engine | state |
|---|---|---|---|
| `plant_vocabulary` | what a node class, node type, edge type, property or quantity means | `graph.node_class` … `graph.quantity_term` | **built 2026-10-12**; `kind` includes `quantity` |

"Exploring node types" is this tool. It is not a topology tool: no `as_of`, as already decided.

### Layer 1 — topology (no telemetry)

| tool | answers | engine | state |
|---|---|---|---|
| `plant_find` | which nodes match: text, type (subtypes included), class, utility, metered or not, `site_status`, department | `graph.node`, `graph.measurement`, effective window | **built 2026-10-12**, without department |
| `plant_section` | one node, what it feeds down to `depth`, and what feeds it from outside | `tools/sld.sql` | **built 2026-10-12**; output `o-mcp/subgraph` v1 |
| `plant_section` with `direction: "up"` | the path back to source — "what could have caused this" | `tools/sld.sql`, walking up flow-carrying edges (same shallowest-path rule as `graph.ancestors`) | **built 2026-10-12**; same format, `query.direction` says which way |

- `plant_find` returns a list, not a subgraph: code, name, type, class, utility, metered, number
  of live feeders. It caps its rows and says how many it left out. Department needs the
  node → department mapping (`reference/production_nodes.csv`) in the database first; until
  then the filter is left out, not faked.
- **No separate siblings tool.** Siblings are `plant_section(root=<feeder>, depth=1)`, and the
  section's `parent` scope already shows a node's feeders. The 25 nodes with more than one
  live feeder have one sibling set per feeder, which the section shows and a flat sibling list
  would hide. `graph.siblings` stays for the analysis tools.
- **No separate descendants tool.** That is `plant_section` going down; a flat list of a
  subtree's codes is what analysis tools need internally, not what a model needs to read.

### Layer 2 — instruments

| tool | answers | engine | state |
|---|---|---|---|
| `node_meters` | which devices read this node or its feeders, what each reports, when each last reported, and which quantities the solver can resolve for the node | `graph.measurement`, `public.devices`, `quantity_term`, last reading from telemetry | **built 2026-10-12**; absorbs `meter_status` from `mcp-server.md` §5 |

- Per device: attachment (`NODE`, or the edge it sits on), `role` (`TOTAL` / `SUBMETER` /
  `CHECK`), the reported quantities as codes with unit and `reading`, last reading, and the
  declared versus observed status table (`mcp-tools.md`, gap 5).
- Per node: the resolvable quantities, each marked *measured here* or *inferred*. This is the
  answer for the 83 nodes with no meter of their own or on an edge.
- 3 quantity ids in dev's telemetry have no `quantity_term`. Report them as `unknown` with
  their id, never drop them silently, and treat each as a CSV row for a later migration.
- `graph.v_device_attachment` filters `is_active` only, not the effective window. The server
  must not read it as is; filter `graph.measurement` itself, or fix the view by migration as
  038 did for `v_property_gaps`.

### Layer 3 — values

| tool | answers | engine | state |
|---|---|---|---|
| `meter_readings` | what this node's meters read over a window, per interval | `telemetry_15min_agg` (15 min); `telemetry_data` not exposed | **built 2026-10-12** |
| `node_value` | one resolvable quantity for one or more nodes over a window, with `origin` | `graph.get_node_quantity`, `graph.get_node_derived` | **built 2026-10-12**; was `plant_quantity` in `mcp-server.md` |

- `meter_readings`: `node`, `quantities` (codes), `start`, `end`, `interval`
  (`15min` / `hour` / `day` / `window`). `COUNTER` returns consumption per interval, `SAMPLE`
  returns mean, min and max, power factor is decoded before any statistic. A row cap (say 500
  points) with a message telling the model to widen the interval, never a silent truncation.
- `node_value` is a primitive from the model's side, one number per node, though the solver
  underneath runs over the whole network. Its quantity input is the rule quantities except
  `PF_TOTAL` (whose `AVG` rule averages encoded values), plus `PF_TRUE`: 10 in all, so a request
  for a quantity the solver cannot resolve fails at the schema, not at the database.
- As built (`mcp-tools.md`, "Built"): `meter_readings` takes at most 31 days and 500 points;
  `node_value` whole site-time days, at most 92. Both windows are half-open, in site time.

### Layer 4 — analysis

One tool per question family, not per quantity: `energy_flow` covers water and air by its
`utility` and `quantity` inputs, which is why there is no `water_balance`.

| tool | question | engine | state |
|---|---|---|---|
| `energy_flow` | where the energy, water or air goes in a section over a window; what is unmetered; cost | `graph.get_node_values`, `get_sankey_flow` (`p_is_cost`) | engine ready (SQL); was `plant_flow` |
| `power_factor` | billing PF at `INCOMING_PLN` against PLN's 0.85 rule, `PF_TRUE` per bus, kVArh contributors ranked, capacitor bank status | `pq-analysis/scripts/pf_report.py`, `graph.get_node_derived` | engine exists (Python) |
| `harmonics` | THDv per bus, harmonic current sources ranked per device and phase, against strict 5% TDD | `pq-analysis/scripts/harmonics_report.py`, `THD_VOLTAGE_LN` `INHERIT` | engine exists (Python) |
| `board_loading` | how loaded a board or transformer is against `rated_kva` / `main_breaker_a`, and which ratings are missing | `node_value`, `type_property`, `v_property_gaps` | partly in `harmonics_report.py` (`rated_a`) |
| `plant_health` | for a section: what is unmetered, which meters are silent, which required properties are missing | `v_coverage`, `node_meters`, `v_property_gaps` | to build; views exist |
| `trip_events` | did a subtree go dark together in one bucket (a trip), or stagger (a shutdown) | 60 s `telemetry_data`, `graph.descendants` | not built (§14 of `graph-network-design.md`) |
| voltage, current unbalance | sustained undervoltage, unbalance survey | Python, per §14 | not built |

Each analysis tool returns its own versioned format with `findings[].message`, like
`o-mcp/subgraph`, so the model quotes conclusions instead of deriving them.

**Total: about 12 tools** — 1 + 2 + 1 + 2 + 6 once `trip_events` and the surveys exist.

## 3. Staggered discovery

### What MCP and Hermes offer

| mechanism | how it works | here |
|---|---|---|
| `notifications/tools/list_changed` | the server adds tools later and tells the client | **no.** It needs a session and a server-to-client message; this server is stateless JSON (`mcp-server.md` §3). And Hermes freezes a session's tool set until `/reload-mcp`, `/new` or compaction, so even a stateful server could not unlock tools mid-conversation |
| client-side tool search / deferred loading | the client sends only names, the model searches for schemas (Claude API tool search, Claude Code's deferred tools) | a client feature; Hermes' MCP docs do not describe one. If it arrives, nothing in the server changes |
| Hermes `include` / `exclude`, `enabled`, `lazy` | per-server filters in `~/.hermes/config.yaml` | **yes, but static.** Good for rolling phases out and for per-profile tool sets, not for per-question loading |
| two servers (core, analysis) | Hermes connects to one or both | static, same as above; worth it only if the definitions grow too large (below) |
| a router tool, `analyze(kind, params)` | one tool whose parameters depend on `kind`, schemas fetched on demand | **rejected.** It throws away typed input schemas, enums and a per-tool `outputSchema`, which is exactly the "ontology as JSON Schema enums at registration" rule in CLAUDE.md |
| progressive disclosure in content | short descriptions; detail in `plant_vocabulary` and resources; each response names the useful next call | **yes**, and already the pattern of `mcp-tools.md` |

### Does it need staggering at all?

Not at 12 tools. What drives the size of the definitions is the vocabulary inside the schemas,
not the tool count:

- `quantity_term`: 97 codes, about 13,300 characters with descriptions (roughly 3–4k tokens).
  As a `oneOf` of `{const, description}` in every tool that takes a quantity, it would dominate
  the context by itself.
- `node_type`: 27 types, about 5,500 characters (roughly 1.5k tokens).

So: a `oneOf` with descriptions only where the set is small and the meaning changes how the
model reads the result (utilities, node classes, edge types, the 11 resolvable quantities);
bare enums for node types and for the 97 reported quantity codes, with the meaning one
`plant_vocabulary` call away. That keeps the CLAUDE.md enum rule and keeps validation
server-side, at an estimated 8–10k tokens for the whole catalogue. **Measure it** (the byte
size of `tools/list`) at each phase rather than trust the estimate.

**Measured 2026-10-12** (`tools/mcp_smoke.py`): phase 1 is 29.1 kB, phases 1 and 2 are 54.9 kB,
about 14k tokens. Descriptions and input schemas are 17.5 kB (about 4.4k tokens), inside the
estimate; the estimate left out the output schemas, which are 38.5 kB. They cost context only if
the client hands `outputSchema` to the model; check what Hermes does before deciding whether to
trim them (`mcp-tools.md`, "Built").

### Recommendation

Stagger by **release**, not at run time:

| phase | tools | needs |
|---|---|---|
| 1 | `plant_vocabulary`, `plant_find`, `plant_section` (down and up) | nothing new; no telemetry. **Built 2026-10-12** (`python -m server --phase 1`) |
| 2 | `node_meters`, `meter_readings`, `node_value` | time zone and window limits (`mcp-server.md` §8, open 4–5). **Built 2026-10-12**: shifts are local, the zone is `O_MCP_TZ`, limits as in §2 |
| 3 | `energy_flow`, `power_factor`, `harmonics` | where Python analysis runs (§4) |
| 4 | `board_loading`, `plant_health`, `trip_events`, surveys | ratings collected; 60 s telemetry access |

Within a conversation, the order comes from the responses, not from loading: a `plant_find`
result says "`node_meters` for what is measured here"; a `meter_readings` call across many
nodes is answered with "use `energy_flow`". If `tools/list` passes about 15k tokens, split
into a core and an analysis server and let Hermes profiles choose with `enabled` and `include`.

## 4. Where the analyses run (undecided)

`power_factor` and `harmonics` have engines today: `pf_report.py`, `harmonics_report.py` and
`layered_report.py` in `../pq-analysis` (pandas, numpy, SQLAlchemy). They write markdown and
CSV per run; none returns a structured result. Six options, weighed 2026-10-12, no decision
yet. Decide before phase 3.

### What the reports cost (dev, 2026-10-12)

Run against dev on its telemetry week, `--tenant 3 --window 2026-09-27:2026-10-03`, peak
resident memory from `/usr/bin/time -l` (macOS):

| report | peak memory | CPU | elapsed |
|---|---|---|---|
| `pf_report.py` | 333 MB | 2.3 s | 111 s |
| `harmonics_report.py` | 621 MB | 2.7 s | 135 s |
| `layered_report.py` (imports both) | 627 MB | 4.5 s | 202 s |

- The computation is cheap; the elapsed time is waiting on the database. Dev's
  `telemetry_15min_agg` is a plain table with **no indexes** (`tools/dev_refresh.sh` copies it
  without TimescaleDB), so these times are pessimistic. Production is unmeasured.
- The memory is pandas holding every 15-minute row. Importing pandas, numpy and SQLAlchemy
  alone is 82 MB.
- Two of the three exceed the server's `MemoryMax=384M` (`mcp-server.md` §1) on their own.

### The options

**1. In process: the server imports the reports.**
Any window, nothing new to deploy. But one harmonics run is 620 MB and two concurrent runs
about 1.2 GB, on a 2 GiB instance shared with Hermes (budget in `mcp-server.md` §7). The reports
need refactoring to return data instead of files either way, and the server would depend on a
second repository's code.

**2. A worker process per call.**
The server starts a child with its own memory cap (a transient systemd scope or a second unit),
one at a time, and reads its JSON result. An out-of-memory kill takes the worker, not the server;
any window still works. Still the same 2 GiB instance, and a call of one to two minutes is long
for a chat answer. Viable only once a run's memory is down (option 5).

**3. Precompute on a schedule; the tool serves the latest result.**
A timer runs the reports for the standard windows (billing month, last week, yesterday) and
writes JSON to the server's host, for example `/var/lib/o-mcp/reports/`; the tool reads it.
Answers are instant, nothing heavy runs while a person waits, the reports run as they are, and
the database role stays read-only (files, not a results table). It matches §14 of
`graph-network-design.md`: power quality's consumer is a scheduled report. The cost: only the
precomputed windows can be asked, every answer must carry its window and `computed_at`, and the
batch still needs the memory at run time (at a quiet hour, or with option 6).

**4. Graduate the logic into SQL functions.**
The §14 rule ("things graduate"), and partly done: `graph.get_node_derived` gives `PF_TRUE`,
and the kVArh contributor ranking is the §11.4 query. But the memory moves to the database
host, which falls to 83 MB available during the press-line dashboard episodes
(`mcp-server.md` §1), and harmonics needs per-bucket state that plpgsql handles badly. Fits only
the set-based pieces, and only after the dashboard refresh is fixed.

**5. A lean rewrite for the server.**
A tool needs no report-shaped output. Push the aggregation (monthly maxima, kWh / kVAh ratios,
per-order sums) into SQL so Python receives hundreds of rows instead of every bucket. With
CPU at 2–4 s, memory is the only real cost, and this removes it at the source. It is real work:
re-deriving numbers that already match Grafana, tested against the existing reports' output on
the same window, and a second implementation to keep in step with `../pq-analysis` unless the
reports move onto it too.

**6. Lambda for analysis.**
One function with pandas (a layer or a container image), VPC-attached and reaching Postgres
through PgBouncer as the ingestion Lambdas already do, with 1–2 GB of memory and a 15-minute
limit. The objection in `mcp-server.md` §2 was that an MCP client cannot sign requests with
SigV4; here the MCP server is the caller and signs with the instance's IAM role, so nothing is
public. The cost: a second deployment target, pandas packaged for Lambda, cold starts on top of a
database-bound call, and an IAM role on the Hermes instance that Hermes' own processes must not
be able to use.

### How they combine

The options are not exclusive: 3 can run its batch through 6; 2 depends on 5; 4 can take the
set-based pieces whichever option carries the rest. What would decide it:

- **Production timings.** A read-only run of the reports against production (needs production
  access for that session) gives the real elapsed time. If a run takes seconds there, on-demand
  options (2, 5, 6) become chat-sized; if it takes minutes, option 3 is the only answer that is.
- **Whether people ask for custom windows.** If questions are calendar-shaped ("this month",
  "last week"), option 3 covers them; the server's call log (`mcp-server.md` §5) will show it
  once phase 2 is used.
- **The Hermes instance's measured memory** once Hermes runs (`mcp-server.md` §7).

## 5. Open

1. **Where the Python analyses run.** Six options in §4, no decision. Decide before phase 3.
2. **Department in the database.** `plant_find` and the analyses want "the Texture machines";
   `graph.taxonomy` holds one taxonomy (`FUNCTIONAL`) and the department mapping is still a CSV.
3. **`meter_readings` limits**: built with 31 days and 500 points, and `telemetry_data` (raw)
   not exposed; revisit with production timings and `trip_events`.
4. **`v_device_attachment` and the effective window** (layer 2): bypassed; the server filters
   `graph.measurement` itself. The view still over-reports for any other reader.
5. **Output schemas in `tools/list`**: 70% of its size (§3). Keep, trim descriptions, or drop,
   depending on whether Hermes passes them to the model.

## 6. Shared with the frontend's API (2026-10-26)

The frontend's API (`api/`, `design/frontend.md` §7) was built after phase 2, partly on the
server's code. What to know when work on the server resumes:

**One copy of each query.** `plant/` holds the queries both use: time windows, node resolution, the
vocabulary and its document, the value solve cut at plant changes (`value`), and since 2026-10-26
`find`, `section`, `meters`, `readings` and `sqlfile` (moved from `server/`). A server tool is now
its name, description, input schema and one-line summary around a `plant/` call; the API's route
is its parameters, node ids and cache around the same call. Neither package imports the other.
**A new tool's query goes in `plant/` from the start**, so the frontend can serve it as a widget
without a second copy.

**One format per answer.** The `design/*-v1.schema.json` files are both the tools' `outputSchema`
and the frontend's data contracts (its TypeScript types are to be generated from them). Each
side's tests check answers strictly (every property required, no other allowed), so a field one
side adds must go into the schema, which then describes the other side too. Added for the
frontend, within v1: the node's `id` (nodelist, subgraph, meters), and in readings `query.node_id`,
each series' `device_id` and the `minute` interval, which only the API gives.

**Deliberate differences**, not drift:

| | MCP server | API |
|---|---|---|
| a node is named by | code or name, resolved and reported (`resolve.pick`) | `graph.node.id` (decision 19) |
| `as_of` | required, default today | the range's last day (decision 20, A) |
| `meter_readings` / readings | 31 days, 500 points, 15-minute data only | 92 days, 10,000 points, minutes for ≤ 6 h |
| `node_value` / values | whole site days only | minute, 15-minute or day, chosen from the window (`api/values.py`) |
| cache | none | 30 s, identical requests in flight run once |

**Added for the frontend only (2026-10-30):** `plant/devices.py`, `o-mcp/devicelist` v1 behind
`GET /api/devices`: every device of the register, where the model reads it and the quantities it
reported in the last day. It has no tool; it is a candidate for layer 2 (a device or quantity
lookup without a node first), as `plant_find` is for nodes.

**Worth bringing back to the server:**

1. **`node_value`'s `data_until` for the daily summary** is the day after the tenant's last
   `daily_bucket`, anywhere, so a window ending today reads as complete while today's row is still
   filling. `api/values.py` takes the last day inside the window, and for it the quarter before its
   `last_refreshed` (pgAgent job 4 refreshes every 30 minutes; `design/frontend.md` §10). Move
   `data_until` / `summary_until` from `api/values.py` into `plant/` and have both use it.
2. **Short windows for `node_value`**: the minute and 15-minute resolution choice
   (`api/values.py`, `choose`) could move into `plant/` too, if the agent is to answer "the last
   30 minutes". Open 3 above (raw `telemetry_data`) is the same question for `meter_readings`.
3. **`energy_flow`** (layer 4): the API serves `graph.sankey` and `graph.sankey_diagnostics`
   (`api/reads.py`) in whole days on the last day's network, with `PLANT_CHANGED` and
   `DATA_INCOMPLETE`. A tool can reuse that, but its answer needs a schema of its own first: the
   API answers it in an ad hoc shape. The cost mode is gone since 062.

**Deployment.** `hermes-prs` runs the server as deployed before the move into `plant/`. The next
deploy (`tools/deploy_server.sh`) carries the move and the new id fields, which change no answer
otherwise; run `server/tests` against dev and `tools/mcp_smoke.py` after it, as usual.

