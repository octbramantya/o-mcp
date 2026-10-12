"""Run a psql script's single query from the server, so tools/sld.sql has one copy.

psql substitutes :'name' as a quoted literal and :name as is. Translated here to psycopg's
%(name)s, run through a client-side cursor, which also interpolates literals, so the query sees
exactly what it sees under psql. Every % already in the file is escaped first. A :: cast is left
alone: a variable is a colon not preceded by a colon and followed by a word character or a quote.
"""
import functools
import pathlib
import re

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
_VAR = re.compile(r"(?<![:\w]):(?:'(\w+)'|(\w+))")


def translate(sql):
    return _VAR.sub(lambda m: f"%({m.group(1) or m.group(2)})s", sql.replace("%", "%%"))


@functools.cache
def load(relpath):
    return translate((ROOT_DIR / relpath).read_text())
