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


async def apply_schema(pool: AsyncConnectionPool) -> None:
    """Create any missing tables.

    Every statement in schema.sql uses IF NOT EXISTS, so applying it on each start is safe.
    """
    async with pool.connection() as conn:
        await conn.execute(SCHEMA.read_text())
