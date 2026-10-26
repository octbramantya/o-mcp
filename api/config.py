"""Configuration, from the environment only, as the MCP server's (server/config.py): every key is
required, nothing has a default, and `--env-file` reads the same keys from a file.

The database's host, name and TLS are the DB_* keys the server uses, but the API logs in as its own
role, frontend_api (migration 061), from O_API_DB_USER and O_API_DB_PASSWORD. DB_USER and
DB_PASSWORD are never read: in .env they are dev's superuser.

Each tenant's plant is read through the role frontend.tenant names for it (prs_frontend for tenant
3), with the password O_API_TENANT_<id>_PASSWORD. Every active tenant needs one; the API checks at
startup (api/tenants.py).
"""
import os
import re
from dataclasses import dataclass, field

from server.config import ConfigError, parse_env_file, tls

DB_KEYS = ("LABEL", "HOST", "PORT", "NAME", "SSLMODE")
API_KEYS = ("DB_USER", "DB_PASSWORD", "BIND")
TENANT_PASSWORD = re.compile(r"O_API_TENANT_(\d+)_PASSWORD")

__all__ = ["Config", "ConfigError", "load"]


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
    bind_host: str
    bind_port: int
    tenant_passwords: dict = field(repr=False)

    def conninfo(self, user=None, password=None):
        """frontend_api's connection, or a tenant role's with user and password."""
        return dict(host=self.db_host, port=self.db_port, dbname=self.db_name, user=user or self.db_user,
                    password=password or self.db_password, sslmode=self.db_sslmode,
                    connect_timeout=5, application_name="o-mcp-api",
                    **({"sslrootcert": self.db_sslrootcert} if self.db_sslrootcert else {}))


def load(env_file=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
    if env_file:
        env.update(parse_env_file(env_file))
    missing = [f"DB_{k}" for k in DB_KEYS if not env.get(f"DB_{k}")]
    missing += [f"O_API_{k}" for k in API_KEYS if not env.get(f"O_API_{k}")]
    if missing:
        raise ConfigError(f"missing {', '.join(missing)}. See .env.example.")
    host, _, port = env["O_API_BIND"].rpartition(":")
    if not host or not port.isdigit():
        raise ConfigError(f"O_API_BIND must be host:port, got {env['O_API_BIND']!r}")
    sslmode, rootcert = tls(env)
    passwords = {int(m.group(1)): v for k, v in env.items() if (m := TENANT_PASSWORD.fullmatch(k)) and v}
    return Config(db_label=env["DB_LABEL"], db_host=env["DB_HOST"], db_port=int(env["DB_PORT"]),
                  db_name=env["DB_NAME"], db_user=env["O_API_DB_USER"], db_password=env["O_API_DB_PASSWORD"],
                  db_sslmode=sslmode, db_sslrootcert=rootcert, bind_host=host, bind_port=int(port),
                  tenant_passwords=passwords)
