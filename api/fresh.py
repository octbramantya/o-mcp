"""How far each of a tenant's data sources has got, for the cache (design/frontend.md §6). An answer
read from a source stays valid until that source moves, and the answer tells the browser when that
can next happen, so a widget doesn't ask before then.

    minute    telemetry_data             the newest minute; moves every minute
    quarter   telemetry_15min_agg        the continuous aggregate's last refresh; moves when its policy
                                         runs (every 5 minutes on production), and only then, since
                                         the aggregate is materialized only. Without TimescaleDB (dev),
                                         or if the tenant's role can't see the job, the newest bucket
    summary   daily_energy_cost_summary  the last refresh of the daily summary (pgAgent, every 30 min)

The marks are read at most every POLL, once for every request of the tenant, and only while
requests come in. An answer is cached with the marks read before it was computed, so it is never
newer than the marks say.
"""
import asyncio
import datetime as dt
import logging
import time

from plant.db import rows

POLL = 15.0                                   # seconds a tenant's marks are reused
HOLD_MAX = dt.timedelta(minutes=5)            # the longest a browser is told to wait
SUMMARY_EVERY = dt.timedelta(minutes=30)      # pgAgent job 4: on the hour and the half hour
SOURCES = ("minute", "quarter", "summary")

log = logging.getLogger("o-mcp-api")

MARKS = """
SELECT (SELECT max("timestamp") FROM telemetry_data
         WHERE tenant_id = %(tenant)s AND "timestamp" > now() AT TIME ZONE 'UTC' - interval '1 hour') AS minute,
       (SELECT max(bucket) FROM telemetry_15min_agg
         WHERE tenant_id = %(tenant)s AND bucket > now() AT TIME ZONE 'UTC' - interval '1 day') AS bucket,
       (SELECT max(last_refreshed) FROM daily_energy_cost_summary
         WHERE tenant_id = %(tenant)s AND daily_bucket >= CURRENT_DATE - 3) AS summary
"""

# the refresh policy of public.telemetry_15min_agg, if TimescaleDB is there and the role can see it
REFRESH_JOB = """
SELECT j.job_id, c.materialized_only
FROM timescaledb_information.continuous_aggregates c
JOIN timescaledb_information.jobs j ON j.hypertable_schema = c.materialization_hypertable_schema
 AND j.hypertable_name = c.materialization_hypertable_name AND j.proc_name = 'policy_refresh_continuous_aggregate'
WHERE c.view_schema = 'public' AND c.view_name = 'telemetry_15min_agg'
"""

JOB_STATS = "SELECT last_successful_finish, next_start FROM timescaledb_information.job_stats WHERE job_id = %s"


def _utc(t):
    """Telemetry stores naive UTC; the summary and TimescaleDB answer aware."""
    return None if t is None else t.replace(tzinfo=dt.UTC) if t.tzinfo is None else t.astimezone(dt.UTC)


class Marks:
    """One reading of a tenant's sources: a version per source, and when each can next change."""

    def __init__(self, minute, quarter, summary, quarter_next, at):
        self.versions = {"minute": minute, "quarter": quarter, "summary": summary}
        self.quarter_next, self.at = quarter_next, at

    def version(self, sources):
        return tuple(self.versions[s] for s in sorted(sources))

    def next_change(self, source):
        """The earliest the source can move, as far as is known; None when it isn't."""
        if source == "minute":
            m = self.versions["minute"]
            return None if m is None else m + dt.timedelta(minutes=1)
        if source == "quarter":
            return self.quarter_next
        step = SUMMARY_EVERY.total_seconds()
        return dt.datetime.fromtimestamp((self.at.timestamp() // step + 1) * step, dt.UTC)

    def fresh_until(self, sources, now=None):
        """When an answer read from these sources can first change: never before now, never past
        HOLD_MAX from now. now when any of them can't tell."""
        now = now or dt.datetime.now(dt.UTC)
        nexts = [self.next_change(s) for s in sources]
        if not nexts or None in nexts:
            return now
        return max(now, min(min(nexts), now + HOLD_MAX))


class Freshness:
    def __init__(self, poll=POLL):
        self.poll, self.got, self.running, self.jobs = poll, {}, {}, {}

    async def marks(self, tenant):
        hit = self.got.get(tenant.id)
        if hit and hit[0] > time.monotonic():
            return hit[1]
        task = self.running.get(tenant.id)
        if task is None:
            task = asyncio.ensure_future(self._read(tenant))
            self.running[tenant.id] = task
            task.add_done_callback(lambda _t: self.running.pop(tenant.id, None))
        m = await asyncio.shield(task)
        self.got[tenant.id] = (time.monotonic() + self.poll, m)
        return m

    async def _job(self, conn, tenant):
        """(job id, materialized only) of the aggregate's refresh policy, or None; looked up once."""
        if tenant.id not in self.jobs:
            job = None
            if (await rows(conn, "SELECT to_regclass('timescaledb_information.job_stats') IS NOT NULL AS t"))[0]["t"]:
                found = await rows(conn, REFRESH_JOB)
                job = (found[0]["job_id"], found[0]["materialized_only"]) if found else None
            self.jobs[tenant.id] = job
            log.info("tenant %s: the 15-minute data's version is %s", tenant.id,
                     f"its refresh job {job[0]}" if job else "its newest bucket (no refresh job visible)")
        return self.jobs[tenant.id]

    async def _read(self, tenant):
        async with tenant.tx() as conn:
            r = (await rows(conn, MARKS, {"tenant": tenant.id}))[0]
            job = await self._job(conn, tenant)
            quarter, quarter_next = _utc(r["bucket"]), None
            if job:
                s = await rows(conn, JOB_STATS, (job[0],))
                if s:
                    quarter, quarter_next = _utc(s[0]["last_successful_finish"]), _utc(s[0]["next_start"])
                if not job[1]:
                    # real-time aggregation: the newest bucket follows the minute data
                    quarter, quarter_next = (quarter, _utc(r["minute"])), None
        return Marks(_utc(r["minute"]), quarter, _utc(r["summary"]), quarter_next, dt.datetime.now(dt.UTC))
