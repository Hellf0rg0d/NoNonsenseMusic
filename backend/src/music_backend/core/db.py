"""Provide the database connection pool and schema setup.

A pool keeps a few connections open and lends them out per request, instead of opening a new connection (slow: a
handshake every time) for every request.
"""
from pathlib import Path

from psycopg import AsyncConnection
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from music_backend.core.settings import settings

DATABASE_URL = settings.database_url        # read from .env or the environment; defined in settings.py
SCHEMA = Path(__file__).resolve().parents[3] / "schema.sql"   # backend/schema.sql, three levels above this file


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


async def needs_auth3(conn: AsyncConnection) -> bool:
    """Report whether the database predates the accounts migration.

    A database from before accounts has a likes table with no owner column. schema.sql only creates what is missing,
    so it cannot change those tables: scripts/migrate_auth3.py does, once.
    """
    row = await (await conn.execute(
        """SELECT to_regclass('likes') IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                                   WHERE table_name = 'likes' AND column_name = 'user_id') AS needs""")).fetchone()
    return row["needs"]


async def apply_schema(pool: AsyncConnectionPool) -> None:
    """Create any missing tables and reject a database that predates accounts.

    Every statement in schema.sql uses IF NOT EXISTS, so applying it on each start is safe.
    """
    async with pool.connection() as conn:
        if await needs_auth3(conn):
            raise RuntimeError("This database is from before accounts. Run once, then start again:  "
                               "cd ~/projects/music/backend && uv run python scripts/migrate_auth3.py --username <you>")
        await conn.execute(SCHEMA.read_text())
