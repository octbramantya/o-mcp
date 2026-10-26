"""Passwords, sessions, the failed-log-in limit and the audit log (design/frontend.md §2).

Passwords are hashed with Argon2id (argon2-cffi's defaults), never stored. A session is a random
token in an HttpOnly, Secure, SameSite=Strict cookie; frontend.session holds only its SHA-256, so a
copy of the table opens nothing. A session ends at its expiry, after IDLE without a request, on
log-out, and when a super admin resets the password, disables the account or changes its role or
tenant.

Failed log-ins are counted from the audit log, so the limit holds across restarts and processes:
LIMIT_EMAIL failures for one email, or LIMIT_IP from one address, within LIMIT_WINDOW refuse
further attempts, right password or not, until the window has passed. Refused attempts are logged
but not counted, so an attacker cannot extend a lock-out by hammering it.
"""
import datetime as dt
import hashlib
import ipaddress
import json
import secrets

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from starlette.concurrency import run_in_threadpool

from .db import one

COOKIE = "o_session"
LIFETIME = dt.timedelta(hours=12)
IDLE = dt.timedelta(hours=2)
SEEN_EVERY = dt.timedelta(minutes=1)
LIMIT_WINDOW = dt.timedelta(minutes=15)
LIMIT_EMAIL = 5
LIMIT_IP = 20
MIN_PASSWORD = 12

_hasher = PasswordHasher()
# Verified against when the email matches no account, so a miss takes as long as a wrong password.
_DUMMY = _hasher.hash(secrets.token_urlsafe(16))


class PasswordRejected(ValueError):
    pass


async def hash_password(password):
    return await run_in_threadpool(_hasher.hash, password)


async def verify_password(stored, password):
    """(matches, needs_rehash). A missing account passes stored=None and never matches."""
    def check():
        try:
            _hasher.verify(stored or _DUMMY, password)
        except (VerificationError, InvalidHashError):
            return False, False
        return stored is not None, _hasher.check_needs_rehash(stored)
    return await run_in_threadpool(check)


def check_new_password(new, email, current=None):
    if len(new) < MIN_PASSWORD:
        raise PasswordRejected(f"A password needs at least {MIN_PASSWORD} characters.")
    if new.strip().lower() == email.strip().lower():
        raise PasswordRejected("A password can't be the email address.")
    if current is not None and new == current:
        raise PasswordRejected("The new password must differ from the current one.")


def temporary_password():
    return secrets.token_urlsafe(12)


def new_token():
    return secrets.token_urlsafe(32)


def token_hash(token):
    return hashlib.sha256(token.encode()).digest()


def client_ip(request):
    """The peer's address, or None if it isn't one (a test client). Behind a proxy this is the proxy's;
    trusting X-Forwarded-For waits for the deployment (design/frontend.md §10)."""
    host = request.client.host if request.client else None
    try:
        return str(ipaddress.ip_address(host)) if host else None
    except ValueError:
        return None


async def audit(conn, event, *, actor=None, email=None, tenant=None, target=None, dashboard=None, ip=None,
                detail=None):
    await conn.execute(
        "INSERT INTO frontend.audit (event, actor_id, email, tenant_id, target_user_id, dashboard_id, client_ip,"
        " detail) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
        (event, actor, email, tenant, target, dashboard, ip, json.dumps(detail) if detail is not None else None))


async def locked_out(conn, email, ip):
    got = await one(conn, """
        SELECT count(*) FILTER (WHERE lower(email) = lower(%(email)s)) AS by_email,
               count(*) FILTER (WHERE client_ip = %(ip)s::inet)        AS by_ip
          FROM frontend.audit
         WHERE event = 'login_failed' AND at > now() - %(window)s
           AND detail->>'reason' IS DISTINCT FROM 'locked_out'""",
        {"email": email, "ip": ip, "window": LIMIT_WINDOW})
    return got["by_email"] >= LIMIT_EMAIL or (ip is not None and got["by_ip"] >= LIMIT_IP)


async def start_session(conn, user):
    """A new session for this user row; returns the cookie's token. A user's tenant is their own; an
    admin's is unset until they choose one."""
    token = new_token()
    await conn.execute(
        "INSERT INTO frontend.session (token_sha256, user_id, tenant_id, expires_at) VALUES (%s, %s, %s, now() + %s)",
        (token_hash(token), user["id"], user["tenant_id"] if user["role"] == "user" else None, LIFETIME))
    return token


async def current_session(conn, token):
    """The live session for a cookie's token, with its user, or None. Touches last_seen_at at most
    once a SEEN_EVERY."""
    if not token:
        return None
    s = await one(conn, """
        SELECT s.token_sha256, s.tenant_id, s.last_seen_at,
               u.id AS user_id, u.email, u.display_name, u.role, u.tenant_id AS own_tenant_id,
               u.must_change_password
          FROM frontend.session s JOIN frontend.app_user u ON u.id = s.user_id
         WHERE s.token_sha256 = %s AND s.revoked_at IS NULL AND s.expires_at > now()
           AND s.last_seen_at > now() - %s AND u.disabled_at IS NULL""",
        (token_hash(token), IDLE))
    if s is not None:
        await conn.execute(
            "UPDATE frontend.session SET last_seen_at = now() WHERE token_sha256 = %s AND last_seen_at < now() - %s",
            (s["token_sha256"], SEEN_EVERY))
    return s


async def revoke_sessions(conn, user_id, keep=None):
    await conn.execute(
        "UPDATE frontend.session SET revoked_at = now()"
        " WHERE user_id = %s AND revoked_at IS NULL AND token_sha256 IS DISTINCT FROM %s",
        (user_id, keep))
