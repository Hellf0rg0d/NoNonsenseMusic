"""What each copy's source says it is, kept (migrations/0005): artist ids, album id, kind and year. The server knew
names only; these are what covers, song-or-video and artist pages are decided from (24 Oct)."""
import pytest

from music_backend.models import Listing
from music_backend.services import library
from music_backend.sources import jiosaavn, ytmusic


def run(text, browse=None, page=None):
    r = {"text": text}
    if browse:
        r["navigationEndpoint"] = {"browseEndpoint": {"browseId": browse, "browseEndpointContextSupportedConfigs": {
            "browseEndpointContextMusicConfig": {"pageType": page}}}}
    return r


def search_row(kind="MUSIC_VIDEO_TYPE_ATV"):
    """A YouTube Music songs-search row, shaped as the real reply (24 Oct): Dior, by Pop Smoke, on an album."""
    column = lambda runs: {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": runs}}}
    return {
        "flexColumns": [
            column([run("Dior (Bonus)")]),
            column([run("Pop Smoke", "UCD3fewmHnwmzjA3IeYWovaQ", "MUSIC_PAGE_TYPE_ARTIST"), run(" • "),
                    run("Shoot For The Stars Aim For The Moon", "MPREb_xlxIGVZ3DZY", "MUSIC_PAGE_TYPE_ALBUM"), run(" • "),
                    run("3:37")]),
            column([run("400M plays")]),
        ],
        "playlistItemData": {"videoId": "thk1vwD2p3Y"},
        "overlay": {"musicItemThumbnailOverlayRenderer": {"content": {"musicPlayButtonRenderer": {"playNavigationEndpoint": {
            "watchEndpoint": {"videoId": "thk1vwD2p3Y", "watchEndpointMusicSupportedConfigs": {
                "watchEndpointMusicConfig": {"musicVideoType": kind}}}}}}}},
    }


def test_a_youtube_music_search_row_keeps_its_artists_album_and_kind():
    listing = ytmusic.to_listing(search_row())
    assert (listing.artists, listing.artist_ids) == (["Pop Smoke"], ["UCD3fewmHnwmzjA3IeYWovaQ"])
    assert listing.album_id == "MPREb_xlxIGVZ3DZY"
    assert listing.kind == "audio"
    assert ytmusic.to_listing(search_row("MUSIC_VIDEO_TYPE_OMV")).kind == "video"
    assert ytmusic.to_listing(search_row("MUSIC_VIDEO_TYPE_UGC")).kind == "upload"


def test_artists_read_from_a_video_title_do_not_get_the_uploaders_ids():
    # "slipfunc - until dawn" on Ikigai's channel: the names are read from the title, the id is the channel's
    assert ytmusic.kept_ids(["slipfunc"], [("Ikigai", "UCchannel")]) is None
    assert ytmusic.kept_ids(["Pop Smoke"], [("Pop Smoke", "UCpop")]) == ["UCpop"]
    assert ytmusic.kept_ids(["A", "B"], [("A", None), ("B", "UCb")]) == [None, "UCb"]   # one without: None in its place
    assert ytmusic.kept_ids(["A"], [("A", None)]) is None                            # no id at all: nothing to keep


def test_a_jiosaavn_song_keeps_its_artist_ids_album_and_year():
    result = {"id": "abc", "title": "Dior", "year": "2020", "play_count": "100", "explicit_content": "1",
              "image": "https://c.saavncdn.com/x-150x150.jpg",
              "more_info": {"album": "Shoot For The Stars Aim For The Moon", "album_id": "72198722", "duration": "216",
                            "artistMap": {"primary_artists": [{"name": "Pop Smoke", "id": "5964868"}]}}}
    listing = jiosaavn.to_listing(result)
    assert (listing.artist_ids, listing.album_id, listing.year, listing.kind) == (["5964868"], "72198722", 2020, "audio")


def bare(**identity):
    return Listing(source="ytmusic", id="Y1", title="Dior", artists=["Pop Smoke"], album="Meet The Woo", duration=216,
                   popularity=None, **identity)


@pytest.fixture
async def pool(pool):
    async with pool.connection() as conn:
        await conn.execute("TRUNCATE playlist_members, playlist_items, playlists, events, likes, listings, songs CASCADE")
    yield pool


async def stored(pool):
    async with pool.connection() as conn:
        return await (await conn.execute("SELECT artist_ids, album_id, kind, year FROM listings WHERE source_id = 'Y1'")).fetchone()


@pytest.mark.anyio
async def test_a_copy_stored_without_its_identity_gets_it_when_a_source_returns_it(pool):
    async with pool.connection() as conn:
        await library.resolve_song(conn, [bare()])                       # stored before migrations/0005: nothing known
    assert dict(await stored(pool)) == {"artist_ids": None, "album_id": None, "kind": None, "year": None}
    async with pool.connection() as conn:
        await library.resolve_song(conn, [bare(artist_ids=["UCpop"], album_id="MPREb_woo", kind="audio", year=2019)])
    assert dict(await stored(pool)) == {"artist_ids": ["UCpop"], "album_id": "MPREb_woo", "kind": "audio", "year": 2019}


@pytest.mark.anyio
async def test_what_a_copy_already_knows_is_never_overwritten(pool):
    async with pool.connection() as conn:
        await library.resolve_song(conn, [bare(artist_ids=["UCpop"], album_id="MPREb_woo", kind="audio", year=2019)])
        # an album page later calls it something else (logged out, every album track reads as a video): kept as was
        await library.resolve_song(conn, [bare(artist_ids=["UCother"], album_id="MPREb_other", kind="video", year=2023)])
    assert dict(await stored(pool)) == {"artist_ids": ["UCpop"], "album_id": "MPREb_woo", "kind": "audio", "year": 2019}
