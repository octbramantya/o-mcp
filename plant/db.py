"""Query helpers over a psycopg connection. Each caller holds its own pool (server/db.py, api/db.py)."""
import psycopg
from psycopg.rows import dict_row


async def rows(conn, sql, params=None):
    async with conn.cursor(row_factory=dict_row) as cur:
        await cur.execute(sql, params)
        return await cur.fetchall()


async def client_rows(conn, sql, params):
    """Run with client-side binding, the way psql substitutes :'var' (see server/sqlfile.py)."""
    async with psycopg.AsyncClientCursor(conn, row_factory=dict_row) as cur:
        await cur.execute(sql, params)
        return await cur.fetchall()
