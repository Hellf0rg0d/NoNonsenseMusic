"""Spotify import: which search result counts as the song Spotify named, and a whole import with a fake search."""
from uuid import uuid4

import pytest

from music_backend.models import Listing, SpotifyImportGroup, SpotifyImportSong
from music_backend.services import spotify_import
from music_backend.services.matching import to_song


def song(title: str, artists: list[str], duration: int = 200):
    return to_song([Listing(source="jiosaavn", id=f"imp-{uuid4().hex[:12]}", title=title, artists=artists,
                            album=None, duration=duration, popularity=None)])


def wanted(title: str, artists: list[str], duration_ms: int | None = 200_000) -> SpotifyImportSong:
    return SpotifyImportSong(title=title, artists=artists, duration_ms=duration_ms)


def test_a_version_named_in_the_title_is_the_same_song():
    assert spotify_import.matches(song("Bohemian Rhapsody", ["Queen"]), wanted("Bohemian Rhapsody - Remastered 2011", ["Queen"]))
    assert spotify_import.matches(song("Kesariya (From \"Brahmastra\")", ["Pritam"]), wanted("Kesariya", ["Pritam"]))
    assert spotify_import.matches(song("Despacito (feat. Daddy Yankee)", ["Luis Fonsi", "Daddy Yankee"]),
                                  wanted("Despacito", ["Luis Fonsi"]))
    assert spotify_import.matches(song("Bailando", ["Enrique Iglesias"]), wanted("Bailándo", ["Enrique Iglesias"]))


def test_another_song_another_artist_or_another_length_is_not():
    assert not spotify_import.matches(song("Despacito 2", ["Luis Fonsi"]), wanted("Despacito", ["Luis Fonsi"]))
    # a remix or a live take is another recording: "Despacito - Remix" matched the original once
    assert not spotify_import.matches(song("Despacito", ["Luis Fonsi"]), wanted("Despacito - Remix", ["Luis Fonsi"]))
    assert spotify_import.matches(song("Despacito (Remix)", ["Luis Fonsi"]), wanted("Despacito - Remix", ["Luis Fonsi"]))
    assert not spotify_import.matches(song("Despacito", ["A Cover Band"]), wanted("Despacito", ["Luis Fonsi"]))
    assert not spotify_import.matches(song("Despacito", ["Luis Fonsi"], duration=260), wanted("Despacito", ["Luis Fonsi"]))


def test_titles_in_other_scripts_compare_by_their_letters():
    # an ASCII-only clean-up would empty both titles, and any two Hindi songs would then match
    assert spotify_import.matches(song("तुम ही हो", ["Arijit Singh"]), wanted("तुम ही हो", ["Arijit Singh"]))
    assert not spotify_import.matches(song("तुम ही हो", ["Arijit Singh"]), wanted("चन्ना मेरेया", ["Arijit Singh"]))


@pytest.mark.anyio
async def test_an_import_likes_what_it_finds_and_counts_what_it_does_not(pool, user_id, monkeypatch):
    monkeypatch.setattr(spotify_import, "PAUSE_SECONDS", 0)
    found = song("Imported Song", ["Some Artist"])

    async def search(q: str):
        return [found] if q.startswith("imported song") else []

    groups = [SpotifyImportGroup(songs=[wanted("Imported Song", ["Some Artist"]), wanted("Nowhere", ["Nobody"])]),
              SpotifyImportGroup(name="Road Trip", songs=[wanted("Imported Song", ["Some Artist"])])]
    hub = spotify_import.ImportHub()
    job = hub.start(pool, search, user_id, groups)
    assert hub.running_for(user_id) is job
    for task in list(hub.tasks):
        await task
    assert (job.total, job.done, job.added, job.finished, job.failed) == (3, 3, 2, True, None)
    assert job.missing == ["Nowhere — Nobody"]
    async with pool.connection() as conn:
        liked = (await (await conn.execute("SELECT count(*) AS n FROM likes WHERE user_id = %s", [user_id])).fetchone())["n"]
        playlists = await (await conn.execute("SELECT id, name FROM playlists WHERE user_id = %s", [user_id])).fetchall()
    assert liked == 1
    assert [p["name"] for p in playlists] == ["Road Trip"]
