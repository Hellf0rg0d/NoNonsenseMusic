"""A song's cover is its canonical release's (services/releases.py), and the song plays before its video
(matching.KIND_RANK). The releases here are the real ones, read from the sources' pages on 24 Oct."""
import pytest

from music_backend.models import AlbumDetail, Listing
from music_backend.services import library, releases
from music_backend.services.matching import pick_best, pick_cover, to_song
from music_backend.services.releases import Release, canonical_cover, kind_of


def copy(source, id, album_id, title="Black Beatles", artists=("Rae Sremmurd",), kind="audio", duration=291, image=None):
    return Listing(source=source, id=id, title=title, artists=list(artists), album=None, duration=duration, popularity=None,
                   image=image or f"https://img.example/{id}.jpg", album_id=album_id, kind=kind)


def release(source, id, artists, kind, year, tracks):
    return Release(source=source, id=id, title=id, artists=list(artists), year=year, track_count=tracks, kind=kind,
                   image=f"https://img.example/cover-{id}.jpg")


SREMMLIFE_2 = release("jiosaavn", "sremmlife2", ["Rae Sremmurd"], "album", 2016, 11)
HYPE_MODE = release("jiosaavn", "hypemode2023", ["Various Artists"], "compilation", 2023, 40)
MADSONIK = release("jiosaavn", "madsonik", ["Rae Sremmurd"], "single", 2017, 1)
KARAOKE = release("ytmusic", "karaoke", ["Singer's Edge Karaoke"], "single", 2017, 2)


def test_black_beatles_shows_its_album_not_a_compilation_or_a_remix_single():
    copies = [(copy("jiosaavn", "hm", "hypemode2023"), HYPE_MODE), (copy("jiosaavn", "ms", "madsonik"), MADSONIK),
              (copy("jiosaavn", "s2", "sremmlife2"), SREMMLIFE_2), (copy("ytmusic", "k", "karaoke"), KARAOKE)]
    assert canonical_cover(["Rae Sremmurd"], copies) == SREMMLIFE_2.image
    assert canonical_cover(["Rae Sremmurd"], list(reversed(copies))) == SREMMLIFE_2.image    # whatever the order


def test_an_album_comes_before_the_single_it_came_after():
    # ZEZE: the single (2018) came out before Dying to Live (2018), and is on fewer tracks
    single = release("ytmusic", "zeze", ["Kodak Black"], "single", 2018, 1)
    album = release("ytmusic", "dyingtolive", ["Kodak Black"], "album", 2018, 18)
    copies = [(copy("ytmusic", "a", "zeze", artists=["Kodak Black"]), single),
              (copy("ytmusic", "b", "dyingtolive", artists=["Kodak Black"]), album)]
    assert canonical_cover(["Kodak Black"], copies) == album.image


def test_among_the_artists_albums_the_earliest():
    # Dior by Pop Smoke: Meet The Woo (2019), Shoot For The Stars (2020), Faith (Deluxe) (2022)
    albums = [release("jiosaavn", "faith", ["Pop Smoke"], "album", 2022, 30), release("jiosaavn", "woo", ["Pop Smoke"], "album", 2019, 9),
              release("jiosaavn", "sfts", ["Pop Smoke"], "album", 2020, 19)]
    copies = [(copy("jiosaavn", r.id, r.id, title="Dior", artists=["Pop Smoke"]), r) for r in albums]
    assert canonical_cover(["Pop Smoke"], copies) == albums[1].image


def test_a_song_only_on_compilations_still_gets_one_and_none_known_keeps_its_cover():
    assert canonical_cover(["Rae Sremmurd"], [(copy("jiosaavn", "hm", "hypemode2023"), HYPE_MODE)]) == HYPE_MODE.image
    assert canonical_cover(["Rae Sremmurd"], [(copy("jiosaavn", "x", "unread"), None)]) is None


def album_page(artists, tracks, release_type=None):
    return AlbumDetail(source="jiosaavn", id="x", title="x", artists=artists, year=2020,
                       songs=[to_song([copy("jiosaavn", f"t{i}", "x")]) for i in range(tracks)], release_type=release_type)


def test_what_a_release_is_comes_from_its_page():
    assert kind_of(album_page(["Various Artists"], 40)) == "compilation"
    assert kind_of(album_page(["Rae Sremmurd"], 11)) == "album"
    assert kind_of(album_page(["Rae Sremmurd"], 1)) == "single"
    assert kind_of(album_page(["Pop Smoke"], 2, release_type="EP")) == "ep"           # the source's own word first


def test_the_song_plays_before_its_video_and_shows_its_own_art():
    song = copy("ytmusic", "song", "dyingtolive", title="ZEZE", artists=["Kodak Black"], duration=229, image="https://img/song.jpg")
    video = copy("ytmusic", "video", None, title="ZEZE", artists=["Kodak Black"], kind="video", duration=277,
                 image="https://img/frame.jpg")
    video = video.model_copy(update={"popularity": 900_000_000})                      # a video's views outnumber plays
    assert pick_best([video, song]).id == "song"
    assert pick_cover([video, song]) == "https://img/song.jpg"


@pytest.fixture
async def pool(pool):
    async with pool.connection() as conn:
        await conn.execute("TRUNCATE playlist_members, playlist_items, playlists, events, likes, listings, songs, releases CASCADE")
    yield pool


@pytest.mark.anyio
async def test_a_stored_song_takes_its_canonical_releases_cover_once_its_pages_are_read(pool):
    pages = {("jiosaavn", "hypemode2023"): HYPE_MODE, ("jiosaavn", "sremmlife2"): SREMMLIFE_2}
    asked = []

    async def fetch(source, album_id):
        asked.append((source, album_id))
        return pages[(source, album_id)]

    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [copy("jiosaavn", "hm", "hypemode2023", image="https://img/basketball.jpg")])
        await library.resolve_song(conn, [copy("jiosaavn", "hm", "hypemode2023"), copy("jiosaavn", "s2", "sremmlife2")])
    assert await releases.refresh_cover(pool, song_id, fetch) == SREMMLIFE_2
    async with pool.connection() as conn:
        row = await (await conn.execute("SELECT image FROM songs WHERE id = %s", [song_id])).fetchone()
    assert row["image"] == SREMMLIFE_2.image
    # a release is read once: asked again, nothing is fetched and nothing changes
    assert await releases.refresh_cover(pool, song_id, fetch) is None
    assert sorted(asked) == [("jiosaavn", "hypemode2023"), ("jiosaavn", "sremmlife2")]


@pytest.mark.anyio
async def test_the_backfill_reads_old_copies_again_lists_first_then_changes_the_cover(pool, user_id):
    from music_backend.core import refresh_covers
    pages = {("jiosaavn", "hypemode2023"): HYPE_MODE, ("jiosaavn", "sremmlife2"): SREMMLIFE_2}

    async def fetch(source, album_id):
        return pages[(source, album_id)]

    async def song_page(song_id):                 # what JioSaavn's song page says each copy is on
        return copy("jiosaavn", song_id, {"hm": "hypemode2023", "s2": "sremmlife2"}[song_id])

    async with pool.connection() as conn:
        # stored before 24 Oct: no album ids, the compilation's basketball as the cover
        old = [copy("jiosaavn", "hm", None, image="https://img/basketball.jpg"), copy("jiosaavn", "s2", None)]
        song_id = await library.resolve_song(conn, old)
        await library.like(conn, user_id, song_id)

    run = lambda apply: refresh_covers.refresh(pool, apply, lookups={"jiosaavn": song_page}, fetch_release=fetch, pause=0)
    assert await run(False) == ["Black Beatles by Rae Sremmurd: sremmlife2 (album, 2016)"]
    async with pool.connection() as conn:
        assert (await (await conn.execute("SELECT image FROM songs WHERE id = %s", [song_id])).fetchone())["image"] == "https://img/basketball.jpg"
        assert (await (await conn.execute("SELECT count(*) AS n FROM releases")).fetchone())["n"] == 0
    assert await run(True) == ["Black Beatles by Rae Sremmurd: sremmlife2 (album, 2016)"]
    async with pool.connection() as conn:
        assert (await (await conn.execute("SELECT image FROM songs WHERE id = %s", [song_id])).fetchone())["image"] == SREMMLIFE_2.image
        assert {r["album_id"] for r in await (await conn.execute("SELECT album_id FROM listings")).fetchall()} == {"hypemode2023", "sremmlife2"}
    assert await run(True) == []                                  # once done, nothing left to change
