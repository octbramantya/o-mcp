"""Configuration, from the environment only. Every key is required; nothing has a default.

In production systemd reads /etc/o-mcp/env. Locally, `--env-file .env` reads the same keys from a
file, parsed and never sourced, the rule tools/_env.sh follows; keys missing from the file are
taken from the process environment (so the O_MCP_* keys can stay out of .env).

DB_SSLMODE is libpq's sslmode. Outside dev it must check the server's certificate (verify-ca or
verify-full) against DB_SSLROOTCERT: production pins PgBouncer's own certificate
(design/mcp-server.md §7). The PG* environment is never read for these: they are always passed.
"""
import os
import pathlib
from dataclasses import dataclass
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DB_KEYS = ("LABEL", "HOST", "PORT", "NAME", "USER", "PASSWORD", "SSLMODE")
SSL_MODES = ("disable", "allow", "prefer", "require", "verify-ca", "verify-full")
VERIFYING = ("verify-ca", "verify-full")
SERVER_KEYS = ("TOKEN", "BIND", "TENANT", "TZ")


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Config:
    db_label: str
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str
    db_sslmode: str
    db_sslrootcert: str | None
    token: str
    bind_host: str
    bind_port: int
    tenant: int
    tz: ZoneInfo

    def conninfo(self):
        return dict(host=self.db_host, port=self.db_port, dbname=self.db_name, user=self.db_user,
                    password=self.db_password, sslmode=self.db_sslmode,
                    connect_timeout=5, application_name="o-mcp",
                    **({"sslrootcert": self.db_sslrootcert} if self.db_sslrootcert else {}))


def parse_env_file(path):
    path = pathlib.Path(path)
    if not path.is_file():
        raise ConfigError(f"{path} not found. Copy .env.example and fill it in.")
    vals = {}
    for raw in path.read_text().splitlines():
        if "=" in raw and not raw.lstrip().startswith("#"):
            k, v = raw.split("=", 1)
            vals[k.strip()] = v.strip().strip("\r").strip('"').strip("'")
    return vals


def tls(env):
    """DB_SSLMODE and DB_SSLROOTCERT, checked: outside dev the server's certificate must be verified."""
    sslmode, rootcert = env["DB_SSLMODE"], env.get("DB_SSLROOTCERT") or None
    if sslmode not in SSL_MODES:
        raise ConfigError(f"DB_SSLMODE must be one of {', '.join(SSL_MODES)}, got {sslmode!r}")
    if env["DB_LABEL"] != "dev" and sslmode not in VERIFYING:
        raise ConfigError(f"DB_SSLMODE {sslmode} does not check the server's certificate; outside dev use "
                          f"verify-ca or verify-full, with DB_SSLROOTCERT")
    if sslmode in VERIFYING:
        if not rootcert:
            raise ConfigError(f"DB_SSLMODE {sslmode} needs DB_SSLROOTCERT, the certificate to trust")
        if not pathlib.Path(rootcert).is_file():
            raise ConfigError(f"DB_SSLROOTCERT {rootcert} not found")
    elif rootcert:
        raise ConfigError(f"DB_SSLROOTCERT is set but DB_SSLMODE {sslmode} does not check certificates")
    return sslmode, rootcert


def load(env_file=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
    if env_file:
        env.update(parse_env_file(env_file))
    missing = [f"DB_{k}" for k in DB_KEYS if not env.get(f"DB_{k}")]
    missing += [f"O_MCP_{k}" for k in SERVER_KEYS if not env.get(f"O_MCP_{k}")]
    if missing:
        raise ConfigError(f"missing {', '.join(missing)}. See .env.example.")
    host, _, port = env["O_MCP_BIND"].rpartition(":")
    if not host or not port.isdigit():
        raise ConfigError(f"O_MCP_BIND must be host:port, got {env['O_MCP_BIND']!r}")
    if len(env["O_MCP_TOKEN"]) < 32:
        raise ConfigError("O_MCP_TOKEN is shorter than 32 characters")
    sslmode, rootcert = tls(env)
    try:
        tz = ZoneInfo(env["O_MCP_TZ"])
    except (ZoneInfoNotFoundError, ValueError) as e:
        raise ConfigError(f"O_MCP_TZ {env['O_MCP_TZ']!r} is not an IANA time zone") from e
    return Config(db_label=env["DB_LABEL"], db_host=env["DB_HOST"], db_port=int(env["DB_PORT"]),
                  db_name=env["DB_NAME"], db_user=env["DB_USER"], db_password=env["DB_PASSWORD"],
                  db_sslmode=sslmode, db_sslrootcert=rootcert,
                  token=env["O_MCP_TOKEN"], bind_host=host, bind_port=int(port),
                  tenant=int(env["O_MCP_TENANT"]), tz=tz)
