"""The connection pool. One transaction per tool call, with its limits set inside it (SET LOCAL),
because PgBouncer's transaction pooling keeps nothing between calls (design/mcp-server.md §4).

The shared public tables (devices, quantities, telemetry_15min_agg, daily_energy_cost_summary,
telemetry_intervals_water, tenant_shift_periods) are always named without a schema. For a tenant's
role (migration 044) its search_path makes them its tenant schema's views, filtered to the tenant;
public.<table> is refused to that role. The graph solver relies on the same, so keep it that way.
"""
from contextlib import asynccontextmanager

from psycopg_pool import AsyncConnectionPool

from plant.db import client_rows, rows  # noqa: F401  (re-exported for the tools)

STATEMENT_TIMEOUT = "20s"


class Database:
    def __init__(self, config):
        self.pool = AsyncConnectionPool(kwargs=config.conninfo(), min_size=1, max_size=4, open=False,
                                        configure=None, check=AsyncConnectionPool.check_connection)

    async def open(self):
        await self.pool.open(wait=True, timeout=10)

    async def close(self):
        await self.pool.close()

    @asynccontextmanager
    async def tx(self, read_only=True):
        """A transaction. Tools that run the solver pass read_only=False: it creates temp tables,
        which a read-only transaction refuses. They still write nothing; the role's grants see to it."""
        async with self.pool.connection() as conn:
            async with conn.transaction():
                if read_only:
                    await conn.execute("SET TRANSACTION READ ONLY")
                await conn.execute(f"SET LOCAL statement_timeout = '{STATEMENT_TIMEOUT}'")
                yield conn

