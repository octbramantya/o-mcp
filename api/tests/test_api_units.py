import pytest

from api import auth, config


def test_token_hash_is_sha256_of_the_token():
    t = auth.new_token()
    assert len(t) >= 43 and len(auth.token_hash(t)) == 32 and auth.token_hash(t) != auth.token_hash(t + "x")


@pytest.mark.parametrize("new, current, match", [
    ("short", None, "at least 12"),
    ("Someone@Example.com", None, "email"),
    ("the same password", "the same password", "differ"),
])
def test_new_password_refusals(new, current, match):
    with pytest.raises(auth.PasswordRejected, match=match):
        auth.check_new_password(new, "someone@example.com", current)


def test_temporary_password_passes_the_rules():
    auth.check_new_password(auth.temporary_password(), "someone@example.com")


def test_config_has_no_defaults_and_never_reads_db_user(monkeypatch):
    for k in ("DB_LABEL", "DB_HOST", "DB_PORT", "DB_NAME", "DB_SSLMODE", "DB_USER", "DB_PASSWORD",
              "O_API_DB_USER", "O_API_DB_PASSWORD", "O_API_BIND"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("DB_USER", "postgres")
    monkeypatch.setenv("DB_PASSWORD", "superuser")
    with pytest.raises(config.ConfigError, match="O_API_DB_USER, O_API_DB_PASSWORD, O_API_BIND"):
        config.load()
    for k, v in dict(DB_LABEL="dev", DB_HOST="h", DB_PORT="5432", DB_NAME="n", DB_SSLMODE="require",
                     O_API_DB_USER="frontend_api", O_API_DB_PASSWORD="p", O_API_BIND="127.0.0.1:1").items():
        monkeypatch.setenv(k, v)
    c = config.load()
    assert (c.conninfo()["user"], c.conninfo()["password"]) == ("frontend_api", "p")


def test_config_refuses_unverified_tls_outside_dev(monkeypatch):
    for k, v in dict(DB_LABEL="prod", DB_HOST="h", DB_PORT="5432", DB_NAME="n", DB_SSLMODE="require",
                     O_API_DB_USER="frontend_api", O_API_DB_PASSWORD="p", O_API_BIND="127.0.0.1:1").items():
        monkeypatch.setenv(k, v)
    with pytest.raises(config.ConfigError, match="does not check the server's certificate"):
        config.load()
