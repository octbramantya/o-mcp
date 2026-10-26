"""A pool per tenant role (design/frontend.md §6, §7). The session says which tenant a request is
for, and this module is the one place that turns it into a pool: choosing the wrong pool is the one
way across tenants, since Postgres keeps each role to its tenant (migration 061) and does the rest.

At startup every active tenant in frontend.tenant gets a pool of its db_role and its vocabulary
(plant/vocab.py). The API refuses to start if a role can't log in, isn't the role it should be, or
can see another tenant's devices.
"""
from contextlib import asynccontextmanager
from dataclasses import dataclass
from zoneinfo import ZoneInfo

from psycopg_pool import AsyncConnectionPool

from plant import vocab as vocabulary
from plant.db import rows

STATEMENT_TIMEOUT = "20s"


class TenantError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


@dataclass
class Tenant:
    id: int
    name: str
    role: str
    tz: ZoneInfo
    pool: AsyncConnectionPool
    vocab: object = None

    @asynccontextmanager
    async def tx(self):
        """One transaction, not read-only: the solver creates temp tables. The role writes nothing."""
        async with self.pool.connection() as conn:
            async with conn.transaction():
                await conn.execute(f"SET LOCAL statement_timeout = '{STATEMENT_TIMEOUT}'")
                yield conn


class Tenants:
    def __init__(self):
        self.by_id = {}

    async def open(self, config, frontend_db):
        async with frontend_db.tx() as conn:
            listed = await rows(conn, "SELECT id, name, db_role, time_zone FROM frontend.tenant WHERE is_active"
                                      " ORDER BY id")
        missing = [f"O_API_TENANT_{t['id']}_PASSWORD" for t in listed if t["id"] not in config.tenant_passwords]
        if missing:
            raise RuntimeError(f"missing {', '.join(missing)}: every active tenant in frontend.tenant needs its "
                               f"role's password")
        for t in listed:
            pool = AsyncConnectionPool(kwargs=config.conninfo(t["db_role"], config.tenant_passwords[t["id"]]),
                                       min_size=1, max_size=4, open=False, check=AsyncConnectionPool.check_connection)
            tenant = Tenant(t["id"], t["name"], t["db_role"], ZoneInfo(t["time_zone"]), pool)
            await pool.open(wait=True, timeout=10)
            self.by_id[t["id"]] = tenant
            async with tenant.tx() as conn:
                r = (await rows(conn, "SELECT current_user AS role, (SELECT count(*) FROM devices"
                                      " WHERE tenant_id <> %s) AS others", (t["id"],)))[0]
                if r["role"] != t["db_role"] or r["others"]:
                    raise RuntimeError(f"tenant {t['id']}'s pool is {r['role']} and sees {r['others']} devices of "
                                       f"other tenants; it must be {t['db_role']}, kept to its tenant (061)")
                tenant.vocab = await vocabulary.load(conn, t["id"])
        return self

    async def close(self):
        for t in self.by_id.values():
            await t.pool.close()

    def for_session(self, s):
        """The tenant a session's request reads. A user's is their own; a session naming another is
        refused (it can't happen through /api/tenant, so it means a bug). An admin must choose one first."""
        if s["tenant_id"] is None:
            raise TenantError(409, "Choose a site first.")
        if s["role"] == "user" and s["tenant_id"] != s["own_tenant_id"]:
            raise TenantError(403, "This session's site isn't the account's.")
        t = self.by_id.get(s["tenant_id"])
        if t is None:
            raise TenantError(404, f"Site {s['tenant_id']} isn't served.")
        return t
