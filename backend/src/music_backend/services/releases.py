"""The releases a song's copies are on, and the cover a song shows: its canonical release's (catalogue identity, 24 Oct).

A recording is on many releases, and its cover came from whichever copy was picked first. Black Beatles is on
JioSaavn's SremmLife 2 and on seven compilations ("Best Rap Workout 2023", "Hip Hop Hype", …: their artists are
"Various Artists"); Dior by Pop Smoke is on five albums, all 216 s. A song in a library showed a basketball, the cover of
the compilation "Hype Mode 2023".

The canonical release (canonical_cover): one by the song's own artist, then an album before an EP before a single, a
compilation only when there is nothing else, then the earliest. Read from each release's own page, never from words in
its name: its artists, its year, its track count and, where the source says, its type.

Learned after a song is stored, in the background (learn_later): each release's page once (the releases table), at
most AT_ONCE at a time and never while a search waits; then the song's cover is chosen again and stored when it changed.
"""
import asyncio
import logging
from dataclasses import dataclass
from uuid import UUID

from music_backend.models import AlbumDetail, Listing
from music_backend.services.library import _stored_listing
from music_backend.services.matching import COVER_PREFERENCE, artists_match, normalise
from music_backend.sources import jiosaavn, ytmusic

logger = logging.getLogger(__name__)

SOURCES = {"ytmusic" : ytmusic, "jiosaavn" : jiosaavn}    # those with album pages; plain YouTube has none
AT_ONCE = 2                       # release pages read at the same time
SINGLE_MOST = 3                   # tracks: a release of 1 to 3 is a single where the source names no type
COMPILATION = "various artists"   # the artists a compilation names, on both sources (24 Oct: 7 of Black Beatles' 8)
KIND_RANK = {"album" : 0, "ep" : 1, "single" : 2, "compilation" : 3}

_running: set[asyncio.Task] = set()                    # held so a task is not collected before it finishes
_asking: set[tuple[str, str]] = set()                  # release pages being read now: each read once
_limits: dict[asyncio.AbstractEventLoop, asyncio.Semaphore] = {}   # one per event loop: a semaphore binds to its loop


@dataclass(frozen = True)
class Release:
    source : str
    id : str
    title : str
    artists : list[str]
    year : int | None
    track_count : int | None
    kind : str
    image : str | None


def kind_of(album: AlbumDetail) -> str:
    """What a release is, from its page: a compilation names "Various Artists"; else the source's own type (YouTube
    Music's Album, EP, Single), else its track count."""
    if any(normalise(a) == COMPILATION for a in album.artists):
        return "compilation"
    if (album.release_type or "").lower() in ("album", "ep", "single"):
        return album.release_type.lower()
    return "single" if 0 < len(album.songs) <= SINGLE_MOST else "album"


def release_of(album: AlbumDetail) -> Release:
    return Release(source = album.source, id = album.id, title = album.title, artists = album.artists, year = album.year,
                   track_count = len(album.songs), kind = kind_of(album), image = album.image)


def canonical_release(song_artists: list[str], copies: list[tuple[Listing, Release | None]]) -> tuple[Listing, Release] | None:
    """A song's canonical release, with the copy on it: by the song's own artist first, then album, EP, single,
    compilation, then the earliest, then COVER_PREFERENCE, then the release id (the same set gives the same release,
    whatever its order). None when none of its releases with a cover is known yet."""
    known = [(copy, release) for copy, release in copies if release is not None and (release.image or copy.image)]
    if not known:
        return None

    def rank(pair: tuple[Listing, Release]):
        copy, release = pair
        by_artist = artists_match(release.artists, song_artists)
        return (0 if by_artist else 1, KIND_RANK[release.kind], release.year or 9999,
                COVER_PREFERENCE.get(release.source, len(COVER_PREFERENCE)), release.id)

    return min(known, key = rank)


def canonical_cover(song_artists: list[str], copies: list[tuple[Listing, Release | None]]) -> str | None:
    """The cover a song shows: its canonical release's, or None when none is known yet (the song keeps the one it has)."""
    chosen = canonical_release(song_artists, copies)
    return chosen and (chosen[1].image or chosen[0].image)


async def stored_releases(conn, keys: list[tuple[str, str]]) -> dict[tuple[str, str], Release]:
    if not keys:
        return {}
    rows = await (await conn.execute(
        """SELECT r.* FROM releases r JOIN unnest(%s::text[], %s::text[]) AS k(source, source_id)
             ON (r.source, r.source_id) = (k.source, k.source_id)""",
        [[s for s, _ in keys], [i for _, i in keys]],
    )).fetchall()
    return {(r["source"], r["source_id"]): Release(source = r["source"], id = r["source_id"], title = r["title"],
                                                   artists = r["artists"], year = r["year"], track_count = r["track_count"],
                                                   kind = r["kind"], image = r["image"]) for r in rows}


async def store_release(conn, release: Release) -> None:
    await conn.execute(
        """INSERT INTO releases (source, source_id, title, artists, year, track_count, kind, image)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
           ON CONFLICT (source, source_id) DO UPDATE SET title = EXCLUDED.title, artists = EXCLUDED.artists,
               year = EXCLUDED.year, track_count = EXCLUDED.track_count, kind = EXCLUDED.kind, image = EXCLUDED.image,
               fetched_at = now()""",
        [release.source, release.id, release.title, release.artists, release.year, release.track_count, release.kind,
         release.image],
    )


async def fetch(source: str, album_id: str) -> Release | None:
    """One release's page, as a Release; None when the source has no such page (or answers without tracks)."""
    album = await SOURCES[source].get_album(album_id)
    return release_of(album) if album else None


async def refresh_cover(pool, song_id: UUID, fetch_release = None, *, copies: list[Listing] | None = None,
                        write: bool = True) -> Release | None:
    """Read the pages of the song's releases not read yet, then choose its cover again; returns the canonical release
    when the cover changes, else None. fetch_release: fetch, unless a test gives another. copies: the song's stored
    ones, unless given. write: store the pages and the cover (without it, only say what would change)."""
    fetch_release = fetch_release or fetch
    async with pool.connection() as conn:
        song = await (await conn.execute("SELECT artists, image FROM songs WHERE id = %s", [song_id])).fetchone()
        if copies is None:
            copies = [_stored_listing(r) for r in await (await conn.execute(
                "SELECT * FROM listings WHERE song_id = %s", [song_id])).fetchall()]
    if song is None:
        return None
    keys = sorted({(c.source, c.album_id) for c in copies if c.album_id and c.source in SOURCES})
    async with pool.connection() as conn:
        known = await stored_releases(conn, keys)
    limit = _limits.setdefault(asyncio.get_running_loop(), asyncio.Semaphore(AT_ONCE))
    for key in keys:
        if key in known or key in _asking:
            continue
        _asking.add(key)
        try:
            async with limit:
                release = await fetch_release(*key)
            if release is not None:
                if write:
                    async with pool.connection() as conn:
                        await store_release(conn, release)
                known[key] = release
        except Exception as e:                    # a page that will not load: the cover stays as it is
            logger.info("releases: %s %s not read (%s)", key[0], key[1], type(e).__name__)
        finally:
            _asking.discard(key)
    chosen = canonical_release(song["artists"], [(c, known.get((c.source, c.album_id))) for c in copies])
    cover = chosen and (chosen[1].image or chosen[0].image)
    if cover is None or cover == song["image"]:
        return None
    if write:
        async with pool.connection() as conn:
            await conn.execute("UPDATE songs SET image = %s WHERE id = %s", [cover, song_id])
    return chosen[1]


def learn_later(pool, song_id: UUID) -> None:
    """After a song is stored: its releases read and its cover chosen again, in the background, never awaited."""
    async def run():
        try:
            await refresh_cover(pool, song_id)
        except Exception as e:                    # a background task: logged, never raised into a request
            logger.warning("releases: song %s: %s", song_id, type(e).__name__)
    task = asyncio.get_running_loop().create_task(run())
    _running.add(task)
    task.add_done_callback(_running.discard)
