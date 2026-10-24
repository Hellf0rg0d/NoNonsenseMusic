"""One recording, one song (migrations/0007): copies join by core title and credit, and two stored songs of one
recording are merged, recorded, and can be split again. The ZEZE copies are as the sources listed them on 24 Oct."""
import pytest

from music_backend.models import Listing
from music_backend.services import library
from music_backend.services.matching import core_title, group_listings, same_recording


def copy(source, id, title, duration, artists=("Kodak Black",), album=None, kind=None):
    return Listing(source=source, id=id, title=title, artists=list(artists), album=album, duration=duration, popularity=None,
                   kind=kind)


SAAVN = copy("jiosaavn", "js1", "ZEZE (feat. Travis Scott & Offset)", 228)
YTM = copy("ytmusic", "yt1", "ZEZE (feat. Offset & Travis Scott)", 229)


def test_zeze_in_either_feature_order_is_one_recording():
    assert core_title(SAAVN.title) == core_title(YTM.title) == "zeze"
    assert same_recording(SAAVN, YTM)
    # who is featured, said in the title on one source and in the artists on another
    assert same_recording(SAAVN, copy("ytmusic", "yt2", "ZEZE", 230, artists=["Kodak Black", "Travis Scott", "Offset"]))
    assert same_recording(SAAVN, copy("jiosaavn", "js2", "ZEZE (feat. Travis Scott and Offset)", 229))


def test_a_version_with_someone_more_or_less_is_another_recording():
    original = copy("jiosaavn", "d1", "Despacito", 229, artists=["Luis Fonsi", "Daddy Yankee"])
    remix = copy("jiosaavn", "d2", "Despacito (feat. Justin Bieber)", 228, artists=["Luis Fonsi", "Daddy Yankee"])
    assert not same_recording(original, remix)
    assert not same_recording(SAAVN, copy("ytmusic", "z", "ZEZE (feat. Offset)", 229))


def test_a_source_that_leaves_out_who_is_featured_has_the_same_recording_on_the_same_album():
    # as stored on the server, 24 Oct: JioSaavn leaves the feature out, YouTube Music names it
    plain = copy("jiosaavn", "bb", "Black Beatles", 292, artists=["Rae Sremmurd"], album="SremmLife 2")
    named = copy("ytmusic", "bbf", "Black Beatles (feat. Gucci Mane)", 292, artists=["Rae Sremmurd"], album="SremmLife 2 (Deluxe)")
    assert same_recording(plain, named)
    on_a_compilation = named.model_copy(update={"album": "Hype Mode 2023"})
    assert not same_recording(plain, on_a_compilation)              # nothing shared to go by: left apart
    # a remix single is named after the song: no evidence that the two are one recording
    original = copy("jiosaavn", "d1", "Despacito", 229, artists=["Luis Fonsi"], album="Despacito")
    remix = copy("ytmusic", "d2", "Despacito (feat. Justin Bieber)", 228, artists=["Luis Fonsi"], album="Despacito (Remix)")
    assert not same_recording(original, remix)


def test_a_music_video_is_its_songs_copy_within_ninety_seconds():
    video = copy("ytmusic", "omv", "ZEZE (feat. Offset & Travis Scott)", 277, kind="video")
    assert same_recording(SAAVN, video) and same_recording(video, SAAVN)
    assert not same_recording(SAAVN, YTM.model_copy(update={"duration": 277}))    # a song that long is another edit
    assert not same_recording(SAAVN, copy("ytmusic", "omv2", "ZEZE (Live)", 290, kind="video"))


def test_a_search_groups_the_sources_copies_and_leaves_the_karaoke_out():
    found = [SAAVN, copy("jiosaavn", "js3", "ZEZE (feat. Travis Scott & Offset)", 229), YTM,
             copy("ytmusic", "yt3", "ZEZE (feat. Offset & Travis Scott)", 230),
             copy("ytmusic", "k", "ZEZE (Originally Performed by Kodak Black, Travis Scott and Offset) [Instrumental]", 228,
                  artists=["3 Dope Brothas"])]
    assert [len(g) for g in group_listings(found)] == [4, 1]


@pytest.fixture
async def pool(pool):
    async with pool.connection() as conn:
        await conn.execute("TRUNCATE playlist_members, playlist_items, playlists, events, likes, listings, songs, song_merges CASCADE")
    yield pool


async def stored_before(conn, listing):
    """A song as stored before migrations/0007: found by its whole title only, no core title."""
    from music_backend.services.matching import normalise
    song_id = (await (await conn.execute(
        "INSERT INTO songs (title, artists, duration, normalised_title) VALUES (%s, %s, %s, %s) RETURNING id",
        [listing.title, listing.artists, listing.duration, normalise(listing.title)])).fetchone())["id"]
    await conn.execute("""INSERT INTO listings (source, source_id, song_id, title, artists, album, duration, popularity, words)
                          VALUES (%s, %s, %s, %s, %s, NULL, %s, NULL, '{}')""",
                       [listing.source, listing.id, song_id, listing.title, listing.artists, listing.duration])
    return song_id


async def song_of(conn, source, source_id):
    return (await (await conn.execute("SELECT song_id FROM listings WHERE source = %s AND source_id = %s",
                                      [source, source_id])).fetchone())["song_id"]


@pytest.mark.anyio
async def test_the_second_source_finds_the_song_the_first_stored(pool):
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, [SAAVN])
        assert await library.resolve_song(conn, [YTM]) == song_id


@pytest.mark.anyio
async def test_two_stored_songs_of_one_recording_become_one_and_can_be_split_again(pool, user_id):
    async with pool.connection() as conn:
        older = await library.resolve_song(conn, [SAAVN])
        newer = await stored_before(conn, YTM)                    # ZEZE, stored twice before 24 Oct
        await library.like(conn, user_id, newer)
        await library.record_event(conn, user_id, newer, "play", 0)
        playlist = await library.create_playlist(conn, user_id, "rap")
        item = await library.add_to_playlist(conn, user_id, playlist, newer)

        assert await library.resolve_song(conn, [SAAVN, YTM]) == older           # one like's copies were on both
        assert await song_of(conn, "ytmusic", "yt1") == older
        assert [s.id for s in await library.liked_songs(conn, user_id)] == [older]
        assert (await (await conn.execute("SELECT song_id FROM playlist_items WHERE id = %s", [item])).fetchone())["song_id"] == older
        merge = await (await conn.execute("SELECT into_id, why FROM song_merges WHERE from_id = %s", [newer])).fetchone()
        assert merge["into_id"] == older
        assert await (await conn.execute("SELECT 1 FROM songs WHERE id = %s", [newer])).fetchone() is None

        assert await library.split_song(conn, newer)
        assert await song_of(conn, "ytmusic", "yt1") == newer
        assert await song_of(conn, "jiosaavn", "js1") == older
        assert [s.id for s in await library.liked_songs(conn, user_id)] == [newer]   # liked as it was, not twice
        assert (await (await conn.execute("SELECT song_id FROM playlist_items WHERE id = %s", [item])).fetchone())["song_id"] == newer
        assert (await (await conn.execute("SELECT count(*) AS n FROM events WHERE song_id = %s", [newer])).fetchone())["n"] == 1
        assert await (await conn.execute("SELECT 1 FROM song_merges")).fetchone() is None


@pytest.mark.anyio
async def test_a_like_of_both_stays_one_like_and_a_merged_id_still_unlikes(pool, user_id):
    async with pool.connection() as conn:
        older = await library.resolve_song(conn, [SAAVN])
        newer = await stored_before(conn, YTM)
        await library.like(conn, user_id, older)
        await library.like(conn, user_id, newer)
        await library.resolve_song(conn, [YTM, SAAVN])
        assert [s.id for s in await library.liked_songs(conn, user_id)] == [older]
        assert await library.unlike(conn, user_id, newer)                        # the id an app still holds
        assert await library.liked_songs(conn, user_id) == []


@pytest.mark.anyio
async def test_a_new_copy_matching_two_stored_songs_merges_them(pool):
    async with pool.connection() as conn:
        older = await library.resolve_song(conn, [SAAVN])
        newer = await stored_before(conn, YTM)
        fresh = copy("ytmusic", "yt9", "ZEZE (feat. Offset & Travis Scott)", 230)
        assert await library.resolve_song(conn, [fresh]) == older
        assert {await song_of(conn, "ytmusic", i) for i in ("yt1", "yt9")} == {older}
        assert (await (await conn.execute("SELECT into_id FROM song_merges WHERE from_id = %s", [newer])).fetchone())["into_id"] == older


@pytest.mark.anyio
async def test_the_backfill_merges_a_video_stored_alone_and_a_song_stored_without_its_feature(pool):
    from music_backend.core import merge_songs
    async with pool.connection() as conn:
        song = await library.resolve_song(conn, [SAAVN])
        video = await stored_before(conn, copy("ytmusic", "omv", "ZEZE (feat. Offset & Travis Scott)", 277))
        await conn.execute("UPDATE listings SET kind = 'video' WHERE source_id = 'omv'")      # as the backfill reads it
        plain = await library.resolve_song(conn, [copy("jiosaavn", "bb", "Black Beatles", 292, artists=["Rae Sremmurd"],
                                                       album="SremmLife 2")])
        await stored_before(conn, copy("ytmusic", "bbf", "Black Beatles (feat. Gucci Mane)", 292, artists=["Rae Sremmurd"]))
        await conn.execute("UPDATE listings SET album = 'SremmLife 2 (Deluxe)' WHERE source_id = 'bbf'")
    assert len(await merge_songs.merge(pool, apply=True)) == 2
    async with pool.connection() as conn:
        assert await song_of(conn, "ytmusic", "omv") == song
        assert await song_of(conn, "ytmusic", "bbf") == plain
        assert (await (await conn.execute("SELECT 1 FROM songs WHERE id = %s", [video])).fetchone()) is None


@pytest.mark.anyio
async def test_a_song_made_from_a_video_takes_its_audio_copy_and_keeps_taking_them(pool):
    async with pool.connection() as conn:
        song = await library.resolve_song(conn, [copy("ytmusic", "omv", "ZEZE (feat. Offset & Travis Scott)", 277, kind="video")])
        assert await library.resolve_song(conn, [SAAVN]) == song
        assert await library.resolve_song(conn, [copy("jiosaavn", "js9", "ZEZE (feat. Travis Scott & Offset)", 229)]) == song


@pytest.mark.anyio
async def test_songs_stored_before_get_their_core_titles_at_start(pool):
    async with pool.connection() as conn:
        newer = await stored_before(conn, YTM)
        assert await library.fill_core_titles(conn) == 1
        assert (await (await conn.execute("SELECT core_title FROM songs WHERE id = %s", [newer])).fetchone())["core_title"] == "zeze"
        assert await library.fill_core_titles(conn) == 0


@pytest.mark.anyio
async def test_the_backfill_lists_first_then_merges_and_never_chains(pool):
    from music_backend.core import merge_songs
    async with pool.connection() as conn:
        first = await stored_before(conn, SAAVN)
        second = await stored_before(conn, YTM)
        # 200, 204, 208 s: each 4 s from the next, but the first and last are not one recording
        await stored_before(conn, copy("jiosaavn", "a", "Drift", 200, artists=["Alex"]))
        await stored_before(conn, copy("jiosaavn", "b", "Drift", 204, artists=["Alex"]))
        await stored_before(conn, copy("jiosaavn", "c", "Drift", 208, artists=["Alex"]))
    listed = await merge_songs.merge(pool, apply=False)
    assert len(listed) == 2                                      # ZEZE's second spelling, and Drift's 204 s
    async with pool.connection() as conn:
        assert (await (await conn.execute("SELECT count(*) AS n FROM songs")).fetchone())["n"] == 5   # nothing yet
    assert await merge_songs.merge(pool, apply=True) == listed
    async with pool.connection() as conn:
        assert await song_of(conn, "ytmusic", "yt1") == first
        assert (await (await conn.execute("SELECT count(*) AS n FROM songs")).fetchone())["n"] == 3
        assert (await (await conn.execute("SELECT 1 FROM song_merges WHERE from_id = %s", [second])).fetchone()) is not None
    assert await merge_songs.merge(pool, apply=False) == []      # run again: nothing left
