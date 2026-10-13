"""Exercise the library services against the `music_test` database.

The database is wiped before every test; the real `music` database is never touched.
"""
import re

import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.services import library
from music_backend.models import Listing
from conftest import TEST_URL, sign_up



def listing(source, id, title="Blinding Lights", artists=("The Weeknd",), duration=200):
    """Build a Listing with test defaults for title, artists and duration."""
    return Listing(source=source, id=id, title=title, artists=list(artists), album=None, duration=duration, popularity=None)


@pytest.fixture
async def pool(pool):
    """conftest's pool, with the library's tables emptied: each test here starts from no songs."""
    async with pool.connection() as conn:
        await conn.execute("TRUNCATE playlist_members, playlist_items, playlists, events, likes, listings, songs CASCADE")
    yield pool


async def count(pool, table):
    async with pool.connection() as conn:
        return (await (await conn.execute(f"SELECT count(*) AS n FROM {table}")).fetchone())["n"]


@pytest.mark.anyio
async def test_like_survives_a_restart(pool, user_id):
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [listing("jiosaavn", "fW-Mxsnu"), listing("ytmusic", "J7p4bzqLvCw", duration=202)])
        await library.like(conn, user_id, song_id)
    await pool.close()                                  # A new pool stands in for a restart
    fresh = db.make_pool(TEST_URL)
    await fresh.open()
    async with fresh.connection() as conn:
        songs = await library.liked_songs(conn, user_id)
    await fresh.close()
    assert [s.id for s in songs] == [song_id]
    assert {l.source for l in songs[0].listings} == {"jiosaavn", "ytmusic"}


@pytest.mark.anyio
async def test_same_song_from_a_later_search_is_not_duplicated(pool):
    async with pool.connection() as conn:
        first = await library.resolve_song(conn, [listing("jiosaavn", "A"), listing("ytmusic", "Y", duration=202)])
        # A later search: different order, plus a release the server has never seen
        second = await library.resolve_song(conn, [listing("jiosaavn", "NEW", duration=204), listing("jiosaavn", "A")])
    assert first == second
    assert await count(pool, "songs") == 1
    assert await count(pool, "listings") == 3           # The new release was linked to the song


@pytest.mark.anyio
async def test_unseen_listing_found_through_the_title_index(pool):
    async with pool.connection() as conn:
        first = await library.resolve_song(conn, [listing("jiosaavn", "A")])
        second = await library.resolve_song(conn, [listing("ytmusic", "Y", duration=202)])   # No shared listing
    assert first == second


@pytest.mark.anyio
async def test_centre_does_not_drift_across_searches(pool):
    async with pool.connection() as conn:
        s1 = await library.resolve_song(conn, [listing("jiosaavn", "A", duration=200)])
        # A later group {204, 208}: 204 is linked via the title index; 208 is 8 s from the frozen centre of 200
        await library.resolve_song(conn, [listing("jiosaavn", "B", duration=204), listing("jiosaavn", "C", duration=208)])
        linked = await (await conn.execute("SELECT source_id FROM listings WHERE song_id = %s ORDER BY source_id", [s1])).fetchall()
    assert [r["source_id"] for r in linked] == ["A", "B"]


@pytest.mark.anyio
async def test_cover_becomes_its_own_song(pool):
    async with pool.connection() as conn:
        weeknd = await library.resolve_song(conn, [listing("jiosaavn", "A")])
        loi = await library.resolve_song(conn, [listing("ytmusic", "L", artists=("Loi",), duration=148)])
    assert weeknd != loi


@pytest.mark.anyio
async def test_liking_twice_is_one_like(pool, user_id):
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [listing("jiosaavn", "A")])
        await library.like(conn, user_id, song_id)
        await library.like(conn, user_id, song_id)
    assert await count(pool, "likes") == 1


@pytest.mark.anyio
async def test_unlike(pool, user_id):
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [listing("jiosaavn", "A")])
        await library.like(conn, user_id, song_id)
        assert await library.unlike(conn, user_id, song_id) is True
        assert await library.unlike(conn, user_id, song_id) is False
        assert await library.liked_songs(conn, user_id) == []


@pytest.mark.anyio
async def test_events_are_stored_and_countable(pool, user_id):
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [listing("jiosaavn", "A")])
        await library.record_event(conn, user_id, song_id, "play", 0)
        await library.record_event(conn, user_id, song_id, "skip", 12)
        await library.record_event(conn, user_id, song_id, "play", 0)
        await library.record_event(conn, user_id, song_id, "finish", 200)
        rows = await (await conn.execute(
            "SELECT type, count(*) AS n FROM events WHERE song_id = %s GROUP BY type ORDER BY type", [song_id])).fetchall()
        recent = await library.recent_songs(conn, user_id)
    assert {r["type"]: r["n"] for r in rows} == {"finish": 1, "play": 2, "skip": 1}
    assert [s.id for s in recent] == [song_id] and recent[0].liked is False


@pytest.mark.usefixtures("trust_client_listings")
def test_endpoints_end_to_end(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    body = {"listings": [listing("jiosaavn", "E2E").model_dump()]}
    with TestClient(app) as client:                     # The context manager runs the lifespan
        sign_up(client)
        song_id = client.post("/liked", json=body).json()["song_id"]
        assert client.post("/events", json=body | {"type": "play", "position": 0}).json()["song_id"] == song_id
        assert song_id in [s["id"] for s in client.get("/liked").json()]
        assert song_id in [s["id"] for s in client.get("/recent").json()]
        assert client.delete(f"/liked/{song_id}").status_code == 204
        assert client.delete(f"/liked/{song_id}").status_code == 404
        assert client.post("/events", json=body | {"type": "jump", "position": 0}).status_code == 422


# ---------- Explicit and clean versions ----------

async def stored_flags(pool):
    async with pool.connection() as conn:
        rows = await (await conn.execute("SELECT source_id, explicit FROM listings ORDER BY source_id")).fetchall()
    return {r["source_id"]: r["explicit"] for r in rows}


@pytest.mark.anyio
async def test_the_explicit_flag_is_stored_and_read_back(pool, user_id):
    loud = listing("jiosaavn", "E1").model_copy(update={"explicit": True})
    clean = listing("ytmusic", "C1", duration=201).model_copy(update={"explicit": False})
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [loud, clean])
        await library.like(conn, user_id, song_id)
        liked = await library.liked_songs(conn, user_id)
    assert await stored_flags(pool) == {"C1": False, "E1": True}
    assert {l.id: l.explicit for l in liked[0].listings} == {"C1": False, "E1": True}


@pytest.mark.anyio
async def test_an_unknown_flag_is_filled_in_and_a_known_one_is_kept(pool):
    unknown = listing("jiosaavn", "U1")                                   # Stored before flags existed: None
    known = listing("ytmusic", "K1", duration=201).model_copy(update={"explicit": True})
    async with pool.connection() as conn:
        await library.resolve_song(conn, [unknown, known])
        assert await stored_flags(pool) == {"K1": True, "U1": None}
        # Seen again with flags. The known listing arrives (wrongly) as clean and must not be overwritten.
        await library.resolve_song(conn, [unknown.model_copy(update={"explicit": True}), known.model_copy(update={"explicit": False})])
    assert await stored_flags(pool) == {"K1": True, "U1": True}


@pytest.mark.anyio
async def test_a_plain_youtube_result_can_be_liked(pool, user_id):
    # liking a plain-YouTube search result failed the listings check (500, 13 Oct): the source must be storable
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [listing("youtube", "2SM_A6Wmx2I", duration=198)])
        await library.like(conn, user_id, song_id)
        songs = await library.liked_songs(conn, user_id)
    assert [l.source for s in songs if s.id == song_id for l in s.listings] == ["youtube"]


@pytest.mark.anyio
async def test_the_database_allows_exactly_the_sources_the_models_name(pool):
    # one list of sources, checked: the database's copy fell behind models.SourceName once (a YouTube like: 500)
    from typing import get_args
    from music_backend.models import SourceName
    async with pool.connection() as conn:
        check = (await (await conn.execute(
            "SELECT pg_get_constraintdef(oid) AS d FROM pg_constraint WHERE conname = 'listings_source_check'")).fetchone())["d"]
    assert set(re.findall(r"'(\w+)'", check)) == set(get_args(SourceName))


@pytest.mark.anyio
async def test_migrations_run_once_and_are_recorded(pool):
    assert await db.migrate(pool) == [], "a database already up to date runs nothing"
    async with pool.connection() as conn:
        versions = [r["version"] for r in await (await conn.execute("SELECT version FROM schema_migrations ORDER BY version")).fetchall()]
    assert versions[:2] == ["0001", "0002"]
