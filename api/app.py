"""The frontend's HTTP API: log-in, sessions, the tenant switch, the super admin's accounts, users'
dashboards (design/frontend.md §2, §7, §8), and the plant: values (api/values.py) and the other reads
(api/reads.py).

Every request is one transaction on frontend_api's pool; a plant request then reads in a second, on
its tenant's pool (api/tenants.py), once the first has closed. The session, not the request, says who
the caller is and which tenant they are in: a user's tenant is fixed, and a request naming another
is refused, not filtered. An account that must change its password reaches only /api/me,
/api/password and /api/logout until it has.

Requests that change anything are POSTs with a JSON body. Together with the SameSite=Strict cookie
that keeps other sites out: a cross-site form can't send application/json, and a script that tries
gets a CORS preflight, which this API never answers.
"""
import contextlib
import datetime as dt
import functools
import json
import logging
import pathlib
import sys

import jsonschema
import psycopg
from starlette.applications import Starlette
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Route

from plant.errors import PlantError

from . import auth, reads, values
from .cache import Cache
from .db import Database, one, rows
from .tenants import TenantError, Tenants

log = logging.getLogger("o-mcp-api")

ROLES = ("user", "admin", "super_admin")
ADMINS = ("admin", "super_admin")
USER_COLUMNS = ("id, email, display_name, role, tenant_id, must_change_password, created_at, password_changed_at,"
                " last_login_at, disabled_at")


class ApiError(Exception):
    def __init__(self, status, message, code=None):
        super().__init__(message)
        self.status, self.message, self.code = status, message, code or _CODES.get(status, "error")


_CODES = {400: "bad_request", 401: "unauthenticated", 403: "forbidden", 404: "not_found", 409: "conflict",
          415: "unsupported_media_type", 429: "too_many_attempts"}


class Json(JSONResponse):
    def render(self, content):
        return json.dumps(content, ensure_ascii=False, default=_iso).encode()


def _iso(v):
    if isinstance(v, dt.datetime | dt.date):
        return v.isoformat()
    raise TypeError(f"{type(v).__name__} is not JSON")


def _error(e):
    resp = Json({"error": e.code, "message": e.message}, status_code=e.status)
    if e.status == 401:
        resp.delete_cookie(auth.COOKIE, path="/", secure=True, httponly=True, samesite="strict")
    return resp


async def _body(request):
    if request.headers.get("content-type", "").split(";")[0].strip() != "application/json":
        raise ApiError(415, "Send the request body as application/json.")
    try:
        body = json.loads(await request.body() or b"{}")
    except ValueError as e:
        raise ApiError(400, "The request body isn't JSON.") from e
    if not isinstance(body, dict):
        raise ApiError(400, "The request body must be a JSON object.")
    return body


def _text(body, key, required=True):
    v = body.get(key)
    if v is None and not required:
        return None
    if not isinstance(v, str) or not v.strip():
        raise ApiError(400, f"{key} must be a non-empty string.")
    return v


def _id(v, key):
    if isinstance(v, bool) or not isinstance(v, int):
        raise ApiError(400, f"{key} must be an integer.")
    return v


def endpoint(who="session", before_password_change=False, plant=False):
    """who: "anyone" (log-in), "session" (any logged-in account), "admin" (admin or super admin) or
    "super_admin". The handler gets
    (request, conn, session, body); an ApiError rolls the transaction back and becomes the response.
    With plant=True it gets the session's tenant (api/tenants.py) in place of conn, after the
    frontend transaction has closed, so a slow solve holds no frontend_api connection."""
    def wrap(fn):
        @functools.wraps(fn)
        async def handler(request):
            try:
                body = await _body(request) if request.method == "POST" else {}
                async with request.app.state.db.tx() as conn:
                    s = None
                    if who != "anyone":
                        s = await auth.current_session(conn, request.cookies.get(auth.COOKIE))
                        if s is None:
                            raise ApiError(401, "Log in first.")
                        if s["must_change_password"] and not before_password_change:
                            raise ApiError(403, "Change your password first.", "must_change_password")
                        if who == "super_admin" and s["role"] != "super_admin":
                            raise ApiError(403, "Only a super admin manages accounts.")
                        if who == "admin" and s["role"] not in ADMINS:
                            raise ApiError(403, "Only an admin opens other people's dashboards.")
                    if not plant:
                        return await fn(request, conn, s, body)
                return await fn(request, request.app.state.tenants.for_session(s), s, body)
            except ApiError as e:
                return _error(e)
            except TenantError as e:
                return _error(ApiError(e.status, e.message))
            except PlantError as e:
                return _error(ApiError(400, str(e)))
            except psycopg.errors.UniqueViolation:
                return _error(ApiError(409, "An account with that email already exists."))
            except Exception:
                log.exception("%s %s failed", request.method, request.url.path)
                return Json({"error": "failed", "message": "The request failed; the error is logged on the server."},
                            status_code=500)
        return handler
    return wrap


async def _tenant(conn, tenant_id):
    if tenant_id is None:
        return None
    return await one(conn, "SELECT id, name, time_zone FROM frontend.tenant WHERE id = %s AND is_active", (tenant_id,))


async def _me(conn, user, tenant_id):
    """What the frontend needs to draw its frame: the account, the current tenant, and the tenants the
    top bar may switch to (a user's own only)."""
    if user["role"] == "user":
        tenants = [t for t in [await _tenant(conn, user["tenant_id"])] if t]
    else:
        tenants = await rows(conn, "SELECT id, name, time_zone FROM frontend.tenant WHERE is_active ORDER BY id")
    return {"user": {"id": user["id"], "email": user["email"], "display_name": user["display_name"],
                     "role": user["role"]},
            "must_change_password": user["must_change_password"],
            "tenant": await _tenant(conn, tenant_id), "tenants": tenants}


def _as_user(s):
    return {"id": s["user_id"], "email": s["email"], "display_name": s["display_name"], "role": s["role"],
            "tenant_id": s["own_tenant_id"], "must_change_password": s["must_change_password"]}


# -- log-in and the session -----------------------------------------------------------------------
@endpoint("anyone")
async def login(request, conn, _s, body):
    email, password = _text(body, "email").strip(), _text(body, "password")
    ip = auth.client_ip(request)
    user = await one(conn, "SELECT id, email, display_name, password_hash, role, tenant_id, must_change_password,"
                           " disabled_at FROM frontend.app_user WHERE lower(email) = lower(%s)", (email,))
    actor = user["id"] if user else None

    async def refuse(status, reason, message):
        await auth.audit(conn, "login_failed", actor=actor, email=email, ip=ip, detail={"reason": reason})
        return _error(ApiError(status, message))

    if await auth.locked_out(conn, email, ip):
        return await refuse(429, "locked_out", "Too many failed log-ins. Try again in 15 minutes.")
    ok, rehash = await auth.verify_password(user and user["password_hash"], password)
    if not ok:
        return await refuse(401, "no_account" if user is None else "wrong_password", "Wrong email or password.")
    if user["disabled_at"] is not None:
        return await refuse(401, "disabled", "Wrong email or password.")
    if user["role"] == "user" and await _tenant(conn, user["tenant_id"]) is None:
        return await refuse(403, "tenant_inactive", "Your site isn't served by this frontend any more.")

    if rehash:
        await conn.execute("UPDATE frontend.app_user SET password_hash = %s WHERE id = %s",
                           (await auth.hash_password(password), user["id"]))
    await conn.execute("UPDATE frontend.app_user SET last_login_at = now() WHERE id = %s", (user["id"],))
    token = await auth.start_session(conn, user)
    tenant_id = user["tenant_id"] if user["role"] == "user" else None
    await auth.audit(conn, "login", actor=user["id"], email=user["email"], tenant=tenant_id, ip=ip)
    resp = Json(await _me(conn, user, tenant_id))
    resp.set_cookie(auth.COOKIE, token, max_age=int(auth.LIFETIME.total_seconds()), path="/", secure=True,
                    httponly=True, samesite="strict")
    return resp


@endpoint(before_password_change=True)
async def logout(request, conn, s, _body):
    await conn.execute("UPDATE frontend.session SET revoked_at = now() WHERE token_sha256 = %s", (s["token_sha256"],))
    await auth.audit(conn, "logout", actor=s["user_id"], email=s["email"], tenant=s["tenant_id"],
                     ip=auth.client_ip(request))
    resp = Json({"ok": True})
    resp.delete_cookie(auth.COOKIE, path="/", secure=True, httponly=True, samesite="strict")
    return resp


@endpoint(before_password_change=True)
async def me(_request, conn, s, _body):
    return Json(await _me(conn, _as_user(s), s["tenant_id"]))


@endpoint(before_password_change=True)
async def change_password(request, conn, s, body):
    current, new = _text(body, "current_password"), _text(body, "new_password")
    stored = await one(conn, "SELECT password_hash FROM frontend.app_user WHERE id = %s", (s["user_id"],))
    ok, _ = await auth.verify_password(stored["password_hash"], current)
    if not ok:
        raise ApiError(403, "The current password is wrong.")
    try:
        auth.check_new_password(new, s["email"], current)
    except auth.PasswordRejected as e:
        raise ApiError(400, str(e)) from e
    await conn.execute("UPDATE frontend.app_user SET password_hash = %s, must_change_password = FALSE,"
                       " password_changed_at = now() WHERE id = %s", (await auth.hash_password(new), s["user_id"]))
    await auth.revoke_sessions(conn, s["user_id"], keep=s["token_sha256"])
    await auth.audit(conn, "password_changed", actor=s["user_id"], email=s["email"], target=s["user_id"],
                     ip=auth.client_ip(request))
    return Json(await _me(conn, _as_user(s) | {"must_change_password": False}, s["tenant_id"]))


@endpoint()
async def switch_tenant(request, conn, s, body):
    to = _id(body.get("tenant_id"), "tenant_id")
    if s["role"] == "user" and to != s["own_tenant_id"]:
        raise ApiError(403, "Your account belongs to one site; it can't switch to another.")
    if await _tenant(conn, to) is None:
        raise ApiError(404, f"No site {to} is served.")
    if to != s["tenant_id"]:
        await conn.execute("UPDATE frontend.session SET tenant_id = %s WHERE token_sha256 = %s",
                           (to, s["token_sha256"]))
        await auth.audit(conn, "tenant_switched", actor=s["user_id"], email=s["email"], tenant=to,
                         ip=auth.client_ip(request), detail={"from": s["tenant_id"], "to": to})
    return Json(await _me(conn, _as_user(s), to))


# -- accounts (super admin) -----------------------------------------------------------------------
async def _role_and_tenant(conn, body):
    role = body.get("role")
    if role not in ROLES:
        raise ApiError(400, f"role must be one of {', '.join(ROLES)}.")
    tenant_id = body.get("tenant_id")
    if role == "user":
        if await _tenant(conn, _id(tenant_id, "tenant_id")) is None:
            raise ApiError(400, f"No site {tenant_id} is served.")
    elif tenant_id is not None:
        raise ApiError(400, "An admin belongs to no site; leave tenant_id out.")
    return role, tenant_id


async def _target(conn, request, s):
    try:
        uid = int(request.path_params["user_id"])
    except ValueError as e:
        raise ApiError(404, "No such account.") from e
    if uid == s["user_id"]:
        raise ApiError(403, "Change your own account through /api/password, or ask another super admin.")
    u = await one(conn, f"SELECT {USER_COLUMNS} FROM frontend.app_user WHERE id = %s", (uid,))
    if u is None:
        raise ApiError(404, "No such account.")
    return u


@endpoint("super_admin")
async def list_users(_request, conn, _s, _body):
    return Json({"users": await rows(conn, f"SELECT {USER_COLUMNS} FROM frontend.app_user ORDER BY lower(email)")})


@endpoint("super_admin")
async def create_user(request, conn, s, body):
    email = _text(body, "email").strip()
    local, at, domain = email.partition("@")
    if not (local and at and domain) or any(c.isspace() for c in email):
        raise ApiError(400, "email isn't an email address.")
    name = _text(body, "display_name", required=False)
    role, tenant_id = await _role_and_tenant(conn, body)
    temp = auth.temporary_password()
    u = await one(conn, f"""
        INSERT INTO frontend.app_user (email, display_name, password_hash, role, tenant_id, created_by)
        VALUES (%s, %s, %s, %s, %s, %s) RETURNING {USER_COLUMNS}""",
                  (email, name, await auth.hash_password(temp), role, tenant_id, s["user_id"]))
    await auth.audit(conn, "account_created", actor=s["user_id"], email=email, tenant=tenant_id, target=u["id"],
                     ip=auth.client_ip(request), detail={"role": role})
    return Json({"user": u, "temporary_password": temp}, status_code=201)


@endpoint("super_admin")
async def reset_password(request, conn, s, _body):
    u = await _target(conn, request, s)
    temp = auth.temporary_password()
    await conn.execute("UPDATE frontend.app_user SET password_hash = %s, must_change_password = TRUE,"
                       " password_changed_at = now() WHERE id = %s", (await auth.hash_password(temp), u["id"]))
    await auth.revoke_sessions(conn, u["id"])
    await auth.audit(conn, "password_reset", actor=s["user_id"], email=u["email"], tenant=u["tenant_id"],
                     target=u["id"], ip=auth.client_ip(request))
    return Json({"temporary_password": temp})


@endpoint("super_admin")
async def disable_user(request, conn, s, _body):
    u = await _target(conn, request, s)
    if u["disabled_at"] is None:
        await conn.execute("UPDATE frontend.app_user SET disabled_at = now() WHERE id = %s", (u["id"],))
        await auth.revoke_sessions(conn, u["id"])
        await auth.audit(conn, "account_disabled", actor=s["user_id"], email=u["email"], tenant=u["tenant_id"],
                         target=u["id"], ip=auth.client_ip(request))
    return Json({"ok": True})


@endpoint("super_admin")
async def enable_user(request, conn, s, _body):
    u = await _target(conn, request, s)
    if u["disabled_at"] is not None:
        await conn.execute("UPDATE frontend.app_user SET disabled_at = NULL WHERE id = %s", (u["id"],))
        await auth.audit(conn, "account_enabled", actor=s["user_id"], email=u["email"], tenant=u["tenant_id"],
                         target=u["id"], ip=auth.client_ip(request))
    return Json({"ok": True})


@endpoint("super_admin")
async def assign_user(request, conn, s, body):
    """Role and tenant together, since a user needs a tenant and an admin has none. Either change ends
    the account's sessions, whose tenant would otherwise be stale."""
    u = await _target(conn, request, s)
    role, tenant_id = await _role_and_tenant(conn, body)
    if (role, tenant_id) == (u["role"], u["tenant_id"]):
        return Json({"ok": True})
    await conn.execute("UPDATE frontend.app_user SET role = %s, tenant_id = %s WHERE id = %s",
                       (role, tenant_id, u["id"]))
    await auth.revoke_sessions(conn, u["id"])
    ip = auth.client_ip(request)
    if role != u["role"]:
        await auth.audit(conn, "role_changed", actor=s["user_id"], email=u["email"], tenant=tenant_id, target=u["id"],
                         ip=ip, detail={"from": u["role"], "to": role})
    if tenant_id != u["tenant_id"]:
        await auth.audit(conn, "tenant_assigned", actor=s["user_id"], email=u["email"], tenant=tenant_id,
                         target=u["id"], ip=ip, detail={"from": u["tenant_id"], "to": tenant_id})
    return Json({"ok": True})


# -- dashboards -----------------------------------------------------------------------------------
# A dashboard belongs to its owner and a tenant (design/frontend.md §1, 12 and §8): every route works
# in the session's current tenant, and another user's dashboard is answered as if it didn't exist. An
# admin may list and open the dashboards of the current tenant's users, read-only, and copy one into
# their own; each open and copy is audited. Deleting sets deleted_at; frontend_api can't DELETE.
# The document is the frontend's (widgets, channels, the range): the API checks its size and version
# only, until web/ fixes the format.
FORMAT_VERSION = 1
MAX_DOCUMENT = 256 * 1024
DASHBOARD_SCHEMA = pathlib.Path(__file__).resolve().parent.parent / "design" / "dashboard-v1.schema.json"
MAX_TITLE = 200
DASHBOARD_COLUMNS = ("d.id, d.title, d.format_version, d.from_template, d.created_at, d.updated_at,"
                     " d.owner_id, u.email AS owner_email, u.display_name AS owner_name, u.role AS owner_role")


def _title(body, required=True):
    t = _text(body, "title", required)
    if t is not None and len(t.strip()) > MAX_TITLE:
        raise ApiError(400, f"title is longer than {MAX_TITLE} characters.")
    return t and t.strip()


def _document(body):
    doc, version = body.get("document"), body.get("format_version")
    if not isinstance(doc, dict):
        raise ApiError(400, "document must be a JSON object.")
    if len(json.dumps(doc, ensure_ascii=False).encode()) > MAX_DOCUMENT:
        raise ApiError(400, f"document is larger than {MAX_DOCUMENT // 1024} KiB.")
    if _id(version, "format_version") != FORMAT_VERSION:
        raise ApiError(400, f"format_version must be {FORMAT_VERSION}.")
    error = next(iter(sorted(_dashboard_schema().iter_errors(doc), key=lambda e: list(e.absolute_path))), None)
    if error is not None:
        where = "/".join(map(str, error.absolute_path)) or "the top level"
        raise ApiError(400, f"document isn't an o-mcp/dashboard v1 document: at {where}, {error.message}")
    return doc, version


@functools.cache
def _dashboard_schema():
    """design/dashboard-v1.schema.json, which web/ writes to (design/frontend.md §8)."""
    return jsonschema.Draft202012Validator(json.loads(DASHBOARD_SCHEMA.read_text()))


def _shown(d, s, document=None):
    out = {k: d[k] for k in ("id", "title", "format_version", "from_template", "created_at", "updated_at")}
    out["owner"] = {"id": d["owner_id"], "email": d["owner_email"], "display_name": d["owner_name"]}
    out["read_only"] = d["owner_id"] != s["user_id"]
    if document is not None:
        out["document"] = document
    return out


async def _load(conn, s, tenant, did, write=False):
    """A dashboard in the session's tenant: the caller's own, or for an admin reading, one of the
    tenant's users'. Anything else is 404, so ids reveal nothing."""
    d = await one(conn, f"""
        SELECT {DASHBOARD_COLUMNS}, d.document
          FROM frontend.dashboard d JOIN frontend.app_user u ON u.id = d.owner_id
         WHERE d.id = %s AND d.tenant_id = %s AND d.deleted_at IS NULL""", (did, tenant.id))
    if d is None or d["owner_id"] != s["user_id"] and not (s["role"] in ADMINS and d["owner_role"] == "user"):
        raise ApiError(404, "No such dashboard.")
    if write and d["owner_id"] != s["user_id"]:
        raise ApiError(403, "Another user's dashboard is read-only; copy it to change it.")
    return d


async def _dashboard(request, conn, s, write=False):
    """The tenant and the dashboard in the path."""
    tenant = request.app.state.tenants.for_session(s)
    try:
        did = int(request.path_params["dashboard_id"])
    except ValueError as e:
        raise ApiError(404, "No such dashboard.") from e
    return tenant, await _load(conn, s, tenant, did, write)


async def _insert(conn, s, tenant, title, doc, version, template):
    d = await one(conn, """
        INSERT INTO frontend.dashboard (owner_id, tenant_id, title, document, format_version, from_template)
        VALUES (%s, %s, %s, %s, %s, %s) RETURNING id""",
                  (s["user_id"], tenant.id, title, json.dumps(doc), version, template))
    return await _load(conn, s, tenant, d["id"])


@endpoint()
async def list_dashboards(request, conn, s, _body):
    tenant = request.app.state.tenants.for_session(s)
    got = await rows(conn, f"""
        SELECT {DASHBOARD_COLUMNS}
          FROM frontend.dashboard d JOIN frontend.app_user u ON u.id = d.owner_id
         WHERE d.owner_id = %s AND d.tenant_id = %s AND d.deleted_at IS NULL
         ORDER BY d.updated_at DESC""", (s["user_id"], tenant.id))
    return Json({"dashboards": [_shown(d, s) for d in got]})


@endpoint("admin")
async def list_users_dashboards(request, conn, s, _body):
    """The current tenant's users' dashboards, for an admin to open read-only (§1, 17)."""
    tenant = request.app.state.tenants.for_session(s)
    got = await rows(conn, f"""
        SELECT {DASHBOARD_COLUMNS}
          FROM frontend.dashboard d JOIN frontend.app_user u ON u.id = d.owner_id
         WHERE d.tenant_id = %s AND u.role = 'user' AND d.deleted_at IS NULL
         ORDER BY lower(u.email), d.updated_at DESC""", (tenant.id,))
    return Json({"dashboards": [_shown(d, s) for d in got]})


@endpoint()
async def create_dashboard(request, conn, s, body):
    """A blank canvas or a template's document (§1, 13), which the frontend ships and sends here."""
    tenant = request.app.state.tenants.for_session(s)
    title = _title(body)
    doc, version = _document(body)
    template = _text(body, "from_template", required=False)
    d = await _insert(conn, s, tenant, title, doc, version, template)
    return Json(_shown(d, s, d["document"]), status_code=201)


@endpoint()
async def get_dashboard(request, conn, s, _body):
    tenant, d = await _dashboard(request, conn, s)
    if d["owner_id"] != s["user_id"]:
        await auth.audit(conn, "dashboard_opened_by_admin", actor=s["user_id"], email=s["email"], tenant=tenant.id,
                         target=d["owner_id"], dashboard=d["id"], ip=auth.client_ip(request))
    return Json(_shown(d, s, d["document"]))


@endpoint()
async def update_dashboard(request, conn, s, body):
    """Title, document or both. updated_at must be the one the caller last read: a save from a stale
    copy (another tab, another device) is refused with 409, not written over the newer one."""
    tenant, d = await _dashboard(request, conn, s, write=True)
    try:
        seen = dt.datetime.fromisoformat(_text(body, "updated_at"))
    except ValueError as e:
        raise ApiError(400, "updated_at must be the dashboard's updated_at, as last read.") from e
    title = _title(body, required=False) or d["title"]
    doc, version = _document(body) if "document" in body or "format_version" in body else (d["document"],
                                                                                           d["format_version"])
    # the check is in the UPDATE, so of two saves from the same copy only the first is written
    cur = await conn.execute("UPDATE frontend.dashboard SET title = %s, document = %s, format_version = %s"
                             " WHERE id = %s AND updated_at = %s AND deleted_at IS NULL",
                             (title, json.dumps(doc), version, d["id"], seen))
    if cur.rowcount == 0:
        raise ApiError(409, "The dashboard was saved elsewhere since you opened it; reload it first.")
    d = await _load(conn, s, tenant, d["id"])
    return Json(_shown(d, s, d["document"]))


@endpoint()
async def delete_dashboard(request, conn, s, _body):
    _, d = await _dashboard(request, conn, s, write=True)
    await conn.execute("UPDATE frontend.dashboard SET deleted_at = now() WHERE id = %s", (d["id"],))
    return Json({"ok": True})


@endpoint()
async def copy_dashboard(request, conn, s, body):
    """A copy into the caller's own dashboards: of their own, or for an admin of a user's (§2). The copy
    keeps the template it came from; the original is untouched."""
    tenant, d = await _dashboard(request, conn, s)
    title = _title(body, required=False) or f"Copy of {d['title']}"[:MAX_TITLE]
    c = await _insert(conn, s, tenant, title, d["document"], d["format_version"], d["from_template"])
    if d["owner_id"] != s["user_id"]:
        await auth.audit(conn, "dashboard_copied_by_admin", actor=s["user_id"], email=s["email"], tenant=tenant.id,
                         target=d["owner_id"], dashboard=d["id"], ip=auth.client_ip(request),
                         detail={"copy": c["id"]})
    return Json(_shown(c, s, c["document"]), status_code=201)


# -- starred nodes --------------------------------------------------------------------------------
MAX_STARS = 200


async def _stars(conn, s, tenant):
    got = await rows(conn, "SELECT node_id FROM frontend.starred_node WHERE user_id = %s AND tenant_id = %s"
                           " ORDER BY created_at, node_id", (s["user_id"], tenant.id))
    return Json({"nodes": [r["node_id"] for r in got]})


@endpoint()
async def list_stars(request, conn, s, _body):
    """The caller's starred nodes in the session's tenant, in the order starred (the left panel, §5)."""
    return await _stars(conn, s, request.app.state.tenants.for_session(s))


@endpoint()
async def star(request, conn, s, body):
    """{node_id, starred}: star or unstar one node; returns the list. Node ids aren't checked against
    the plant: one not in it today stays listed and the frontend says so, as in a dashboard."""
    tenant = request.app.state.tenants.for_session(s)
    node = _id(body.get("node_id"), "node_id")
    if not isinstance(body.get("starred"), bool):
        raise ApiError(400, "starred must be true or false.")
    if body["starred"]:
        n = await one(conn, "SELECT count(*) AS n FROM frontend.starred_node WHERE user_id = %s AND tenant_id = %s",
                      (s["user_id"], tenant.id))
        if n["n"] >= MAX_STARS:
            raise ApiError(400, f"At most {MAX_STARS} starred nodes.")
        await conn.execute("INSERT INTO frontend.starred_node (user_id, tenant_id, node_id) VALUES (%s, %s, %s)"
                           " ON CONFLICT DO NOTHING", (s["user_id"], tenant.id, node))
    else:
        await conn.execute("DELETE FROM frontend.starred_node WHERE user_id = %s AND tenant_id = %s AND node_id = %s",
                           (s["user_id"], tenant.id, node))
    return await _stars(conn, s, tenant)


# -- the plant ------------------------------------------------------------------------------------
@endpoint(plant=True)
async def get_values(request, tenant, _s, _body):
    q, ids, w = values.parse(request.query_params, tenant)
    # relative ranges from many viewers differ by seconds: one key per minute (design/frontend.md §6)
    key = ("values", tenant.id, q["code"], tuple(ids), values._floor(w.start, values.MINUTE),
           values._ceil(w.end, values.MINUTE))
    return Json(await request.app.state.cache.get(key, lambda: values.run(tenant, q, ids, w)))


def _read(read):
    """A plant route answered by one of api/reads.py's reads, through the cache."""
    @endpoint(plant=True)
    async def handler(request, tenant, _s, _body):
        key, compute = read(tenant, request.query_params)
        return Json(await request.app.state.cache.get(key, compute))
    return handler


# -- the app --------------------------------------------------------------------------------------
def build(config):
    db = Database(config)
    tenants = Tenants()

    async def healthz(_request):
        try:
            async with db.tx() as conn:
                await conn.execute("SELECT 1")
            return PlainTextResponse("ok")
        except Exception:
            log.exception("healthz")
            return PlainTextResponse("database unreachable", status_code=503)

    @contextlib.asynccontextmanager
    async def lifespan(_app):
        await db.open()
        async with db.tx() as conn:
            r = await one(conn, "SELECT current_user AS role, has_schema_privilege('graph', 'USAGE') AS plant,"
                                " (SELECT count(*) FROM frontend.tenant WHERE is_active) AS tenants")
        if r["plant"]:
            log.warning("database role %s can read the plant schema graph: frontend_api (migration 061) can't. "
                        "Expected for a developer's own role; in production, use frontend_api", r["role"])
        await tenants.open(config, db)
        log.info("serving %d tenant(s) on %s as %s: %s", r["tenants"], config.db_label, r["role"],
                 ", ".join(f"{t.id} {t.name} as {t.role}" for t in tenants.by_id.values()))
        yield
        await tenants.close()
        await db.close()

    routes = [
        Route("/healthz", healthz),
        Route("/api/login", login, methods=["POST"]),
        Route("/api/logout", logout, methods=["POST"]),
        Route("/api/me", me, methods=["GET"]),
        Route("/api/password", change_password, methods=["POST"]),
        Route("/api/tenant", switch_tenant, methods=["POST"]),
        Route("/api/admin/users", list_users, methods=["GET"]),
        Route("/api/admin/users", create_user, methods=["POST"]),
        Route("/api/admin/users/{user_id}/reset-password", reset_password, methods=["POST"]),
        Route("/api/admin/users/{user_id}/disable", disable_user, methods=["POST"]),
        Route("/api/admin/users/{user_id}/enable", enable_user, methods=["POST"]),
        Route("/api/admin/users/{user_id}/assign", assign_user, methods=["POST"]),
        Route("/api/dashboards", list_dashboards, methods=["GET"]),
        Route("/api/dashboards", create_dashboard, methods=["POST"]),
        Route("/api/dashboards/{dashboard_id}", get_dashboard, methods=["GET"]),
        Route("/api/dashboards/{dashboard_id}", update_dashboard, methods=["POST"]),
        Route("/api/dashboards/{dashboard_id}/delete", delete_dashboard, methods=["POST"]),
        Route("/api/dashboards/{dashboard_id}/copy", copy_dashboard, methods=["POST"]),
        Route("/api/admin/dashboards", list_users_dashboards, methods=["GET"]),
        Route("/api/stars", list_stars, methods=["GET"]),
        Route("/api/stars", star, methods=["POST"]),
        Route("/api/values", get_values, methods=["GET"]),
        Route("/api/vocabulary", _read(reads.vocabulary_doc), methods=["GET"]),
        Route("/api/nodes", _read(reads.nodes), methods=["GET"]),
        Route("/api/section", _read(reads.subgraph), methods=["GET"]),
        Route("/api/meters", _read(reads.node_meters), methods=["GET"]),
        Route("/api/readings", _read(reads.node_readings), methods=["GET"]),
        Route("/api/sankey", _read(reads.sankey), methods=["GET"]),
        Route("/api/diagnostics", _read(reads.diagnostics), methods=["GET"]),
        Route("/api/categories", _read(reads.categories), methods=["GET"]),
        Route("/api/now", _read(reads.node_now), methods=["GET"]),
        Route("/api/status", _read(reads.data_status), methods=["GET"]),
    ]
    app = Starlette(routes=routes, lifespan=lifespan)
    app.state.db, app.state.tenants, app.state.cache = db, tenants, Cache()
    return app


async def create_super_admin(config, email, display_name=None):
    """The first account, from the command line: nobody signs up, and the API has no account until a
    super admin exists. Returns the temporary password, to be changed at the first log-in."""
    db = Database(config)
    await db.open()
    try:
        temp = auth.temporary_password()
        async with db.tx() as conn:
            u = await one(conn, "INSERT INTO frontend.app_user (email, display_name, password_hash, role)"
                                " VALUES (%s, %s, %s, 'super_admin') RETURNING id",
                          (email.strip(), display_name, await auth.hash_password(temp)))
            await auth.audit(conn, "account_created", email=email.strip(), target=u["id"],
                             detail={"role": "super_admin", "via": "command line"})
        return temp
    finally:
        await db.close()


def configure_logging():
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[handler])
