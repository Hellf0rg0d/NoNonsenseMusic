"""Spotify import: which search result counts as the song Spotify named, and a whole import with a fake search."""
from uuid import uuid4

import pytest

from music_backend.models import Listing, SpotifyImportGroup, SpotifyImportSong
from music_backend.services import spotify_import
from music_backend.services.matching import to_song


def song(title: str, artists: list[str], duration: int = 200, *, source: str = "jiosaavn", id: str | None = None):
    return to_song([Listing(source=source, id=id or f"imp-{uuid4().hex[:11]}", title=title, artists=artists,
                            album=None, duration=duration, popularity=None)])


async def _none(_):
    return None

NO_YOUTUBE = spotify_import.YouTube(track=_none, playlist=_none)


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
    job = hub.start(pool, search, NO_YOUTUBE, user_id, groups)
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


def test_playlist_links_give_their_id():
    assert spotify_import.playlist_id_of("https://music.youtube.com/playlist?list=PLabcdefghij_-12") == "PLabcdefghij_-12"
    assert spotify_import.playlist_id_of("https://www.youtube.com/watch?v=kJQP7kiw5Fk&list=PLxyz0123456789") == "PLxyz0123456789"
    assert spotify_import.playlist_id_of("PLxyz0123456789") == "PLxyz0123456789"
    assert spotify_import.playlist_id_of("https://example.com/nothing") is None


@pytest.mark.anyio
async def test_a_youtube_video_is_found_by_its_id_with_its_other_copies_or_alone():
    video_id = uuid4().hex[:11]
    both = to_song([Listing(source="jiosaavn", id=f"imp-{uuid4().hex[:11]}", title="Same Song", artists=["Band"], album=None,
                            duration=200, popularity=None),
                    Listing(source="ytmusic", id=video_id, title="Same Song", artists=["Band"], album=None,
                            duration=200, popularity=None)])

    async def search(q):
        return [both]

    found = await spotify_import.find(wanted("Same Song", ["Band"]).model_copy(update={"youtube_id": video_id}), search, NO_YOUTUBE)
    assert {l.source for l in found.listings} == {"jiosaavn", "ytmusic"}

    lone = Listing(source="ytmusic", id="Only1234567", title="Only On YouTube", artists=["Someone"], album=None,
                   duration=180, popularity=None)

    async def track(vid):
        return lone if vid == "Only1234567" else None

    async def nothing(q):
        return []

    alone = await spotify_import.find(SpotifyImportSong(youtube_id="Only1234567"), nothing,
                                      spotify_import.YouTube(track=track, playlist=_none))
    assert alone is not None and alone.title == "Only On YouTube"


@pytest.mark.anyio
async def test_a_youtube_link_becomes_a_playlist_and_a_list_can_go_into_an_existing_one(pool, user_id, monkeypatch):
    monkeypatch.setattr(spotify_import, "PAUSE_SECONDS", 0)
    first, second = song("Linked One", ["Band"], source="ytmusic", id=uuid4().hex[:11]), song("Linked Two", ["Band"])

    async def playlist(list_id):
        return ("My YouTube Mix", [SpotifyImportSong(title="Linked One", artists=["Band"], youtube_id=first.listings[0].id)]) \
            if list_id == "PLmix0123456789" else None

    async def search(q):
        return [first] if q.startswith("linked one") else [second] if q.startswith("linked two") else []

    from music_backend.services import library
    async with pool.connection() as conn:
        existing = await library.create_playlist(conn, user_id, "Already Here")
    groups = [SpotifyImportGroup(youtube_playlist="https://music.youtube.com/playlist?list=PLmix0123456789"),
              SpotifyImportGroup(playlist_id=existing, songs=[wanted("Linked Two", ["Band"])])]
    hub = spotify_import.ImportHub()
    job = hub.start(pool, search, spotify_import.YouTube(track=_none, playlist=playlist), user_id, groups)
    for task in list(hub.tasks):
        await task
    assert (job.total, job.added, job.missing, job.failed) == (2, 2, [], None)
    async with pool.connection() as conn:
        rows = await (await conn.execute(
            """SELECT p.name, count(i.*) AS n FROM playlists p LEFT JOIN playlist_items i ON i.playlist_id = p.id
                WHERE p.user_id = %s GROUP BY p.name ORDER BY p.name""", [user_id])).fetchall()
    assert [(r["name"], r["n"]) for r in rows] == [("Already Here", 1), ("My YouTube Mix", 1)]


def test_importing_into_a_playlist_you_cannot_edit_is_refused():
    from fastapi.testclient import TestClient
    from music_backend.main import app
    from conftest import sign_up
    with TestClient(app) as client:
        owner, other = sign_up(client), sign_up(client)
        made = client.post("/playlists", json={"name": "Not Yours"}, headers={"Authorization": f"Bearer {owner['token']}"}).json()
        answer = client.post("/import", headers={"Authorization": f"Bearer {other['token']}"},
                             json={"groups": [{"playlist_id": made["id"], "songs": [{"title": "x", "artists": ["y"]}]}]})
        assert answer.status_code == 404, answer.text


def test_one_artist_written_two_ways_is_the_same_artist():
    assert spotify_import.matches(song("Jaguar", ["Muzical Doctorz Sukh-E", "Bohemia"], 167), wanted("Jaguar", ["Sukh-E Muzical Doctorz"], 166_995))
    assert spotify_import.matches(song("Jaat Da Muqabala", ["Sidhu Moosewala"], 205), wanted("Jaat Da Muqabala", ["Sidhu Moose Wala"], 204_360))
    assert not spotify_import.matches(song("Jaguar", ["L.D Sarda"], 167), wanted("Jaguar", ["Sukh-E Muzical Doctorz"], 166_995))
