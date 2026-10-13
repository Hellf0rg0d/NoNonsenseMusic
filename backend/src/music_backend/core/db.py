"""Provide the database connection pool, and bring the database up to date (migrations).

A pool keeps a few connections open and lends them out per request, instead of opening a new connection (slow: a
handshake every time) for every request.
"""
import logging
from pathlib import Path

from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from music_backend.core.settings import settings

logger = logging.getLogger(__name__)

DATABASE_URL = settings.database_url        # read from .env or the environment; defined in settings.py
MIGRATIONS = Path(__file__).resolve().parents[3] / "migrations"   # backend/migrations, three levels above this file


def make_pool(url: str) -> AsyncConnectionPool:
    # dict_row: rows come back as {"column": value} instead of bare tuples.
    # One connection stays open, up to 8 under load (4 prefetch workers plus the user's requests), and extras close
    # after 60 seconds idle. The library default holds 4 open all the time: 4 Postgres processes of 7-11 MB each.
    # check: a connection is tested as it is lent out, so one that the database or a network device closed while it
    # sat idle is replaced instead of failing a request. statement_timeout: a query running longer than 10 s is
    # cancelled, so one slow statement cannot hold a connection (of 8) and the requests waiting behind it.
    return AsyncConnectionPool(url, open = False,
                               kwargs = {"row_factory" : dict_row, "options" : "-c statement_timeout=10000"},
                               min_size = 1, max_size = 8, max_idle = 60, check = AsyncConnectionPool.check_connection)


async def migrate(pool: AsyncConnectionPool) -> list[str]:
    """Run each migrations/NNNN_*.sql this database has not run yet, in order, and return the files run.

    Each file runs once, in one transaction with its record in schema_migrations. A change to the schema is a new
    numbered file, never an edit to an old one.
    """
    async with pool.connection() as conn:
        await conn.execute("""CREATE TABLE IF NOT EXISTS schema_migrations (
                                  version    text        PRIMARY KEY,
                                  applied_at timestamptz NOT NULL DEFAULT now())""")
        done = {row["version"] for row in await (await conn.execute("SELECT version FROM schema_migrations")).fetchall()}
        # a database made before migrations (by schema.sql, until 13 Oct) is at the baseline: recorded, not run again
        if not done and (await (await conn.execute("SELECT to_regclass('songs') IS NOT NULL AS made")).fetchone())["made"]:
            await conn.execute("INSERT INTO schema_migrations (version) VALUES ('0001')")
            done = {"0001"}
    ran = []
    for path in sorted(MIGRATIONS.glob("[0-9][0-9][0-9][0-9]_*.sql")):
        version = path.name[:4]
        if version in done:
            continue
        async with pool.connection() as conn, conn.transaction():
            await conn.execute(path.read_text())
            await conn.execute("INSERT INTO schema_migrations (version) VALUES (%s)", [version])
        logger.info("migration %s applied", path.name)
        ran.append(path.name)
    return ran
