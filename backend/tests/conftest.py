"""Shared fixtures for the test suite. pytest loads this module on its own; no test file imports it.

- anyio_backend: async tests marked with @pytest.mark.anyio run on asyncio.
- pool: a connection pool on the test database with the schema applied. A file that needs more (test_library drops
  the tables first; test_lyrics_cache deletes its rows afterwards) defines its own `pool`, which takes precedence
  for that file.
- sign_up(client): every route except /health, /auth/signup and /auth/signin requires a token. This helper signs up
  a fresh account through the real route and puts its token on the test client, so later requests act as that user.
- user_id: a fresh account for tests that call the library functions directly.
- trust_client_listings: store the listings a test posts as written, for files about something other than where a
  stored listing's text comes from. Without it a listing the server never returned is refused (422), as it is on the
  internet; test_trusted_listings.py covers that behaviour with the real check.

Test accounts are named test-<random>; their rows are deleted once all tests have run.
"""
from uuid import uuid4

import psycopg
import pytest

from music_backend.core import db
from music_backend.services import auth, library

TEST_URL = "postgresql:///music_test"      # the test database, not a library database: tests write and delete


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
async def pool():
    """Yield a pool on the test database with the schema applied, then close it."""
    pool = db.make_pool(TEST_URL)
    await pool.open()
    await db.apply_schema(pool)
    yield pool
    await pool.close()


def new_username():
    return "test-" + uuid4().hex[:10]


def sign_up(client, username=None) -> dict:
    """Sign up through /auth/signup and send that token on later requests. Return the body: {"token", "user"}."""
    r = client.post("/auth/signup", json={"username": username or new_username(), "password": "a test password"})
    assert r.status_code == 201, r.text
    session = r.json()
    client.headers["Authorization"] = f"Bearer {session['token']}"
    return session


@pytest.fixture
def trust_client_listings(monkeypatch):
    async def as_sent(conn, served, listings):
        return listings
    monkeypatch.setattr(library, "trusted_listings", as_sent)


@pytest.fixture
async def user_id(pool):
    async with pool.connection() as conn:
        return (await auth.create_user(conn, new_username(), "a test password")).id


@pytest.fixture(scope="session", autouse=True)
def _delete_test_accounts():
    yield
    with psycopg.connect(TEST_URL) as conn:
        conn.execute("DELETE FROM users WHERE username LIKE 'test-%'")
