"""The pool of frontend_api connections. One transaction per request, as the MCP server's
(server/db.py): PgBouncer's transaction pooling keeps nothing between them.

Every name is schema-qualified (frontend.*), so the queries mean the same under any role's search_path.
"""
from contextlib import asynccontextmanager

from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

STATEMENT_TIMEOUT = "5s"


class Database:
    def __init__(self, config):
        # frontend_api has CONNECTION LIMIT 4 (061): three here, one left for `python -m api create-super-admin`.
        self.pool = AsyncConnectionPool(kwargs=config.conninfo(), min_size=1, max_size=3, open=False,
                                        check=AsyncConnectionPool.check_connection)

    async def open(self):
        await self.pool.open(wait=True, timeout=10)

    async def close(self):
        await self.pool.close()

    @asynccontextmanager
    async def tx(self):
        async with self.pool.connection() as conn:
            async with conn.transaction():
                await conn.execute(f"SET LOCAL statement_timeout = '{STATEMENT_TIMEOUT}'")
                yield conn


async def rows(conn, sql, params=None):
    async with conn.cursor(row_factory=dict_row) as cur:
        await cur.execute(sql, params)
        return await cur.fetchall()


async def one(conn, sql, params=None):
    got = await rows(conn, sql, params)
    return got[0] if got else None
