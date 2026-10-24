"""Give the songs people keep their canonical release's cover (services/releases.py), the songs stored before it too.

A copy stored before 24 Oct has no album id (migrations/0005), so its song's releases are unknown and its cover stays
whichever copy was picked first: Black Beatles with "Best Rap Workout 2023"'s, a compilation. Each such copy is read
again from its source (JioSaavn's song page; YouTube Music's watch page, which answers a data centre), what it did not
know is filled in, never overwritten, and the song's cover is chosen again. Songs that are liked or in a playlist,
the most recently kept first.

    uv run python -m music_backend.core.refresh_covers            # lists what would change
    uv run python -m music_backend.core.refresh_covers --apply    # changes it
"""
import argparse
import asyncio

from music_backend.core import db
from music_backend.models import Listing
from music_backend.services import releases
from music_backend.services.library import _stored_listing
from music_backend.sources import jiosaavn, ytmusic

PAUSE_SECONDS = 0.3          # between two lookups: a few thousand at once would look like a bot
IDENTITY = ("artist_ids", "album_id", "kind", "year")
LOOKUPS = {"jiosaavn": jiosaavn.get_song, "ytmusic": ytmusic.import_track}


async def kept_songs(conn, limit: int | None) -> list[dict]:
    return await (await conn.execute(
        """SELECT s.id, s.title, s.artists FROM songs s
             JOIN (SELECT song_id, max(at) AS at FROM (SELECT song_id, liked_at AS at FROM likes
                                                       UNION ALL SELECT song_id, added_at FROM playlist_items) k
                    GROUP BY song_id) k ON k.song_id = s.id
            ORDER BY k.at DESC LIMIT %s""", [limit])).fetchall()


async def with_identity(copy: Listing, lookups, pause: float) -> Listing:
    """The copy with what its source says it is now, where it did not know: as stored, when the lookup fails."""
    if copy.album_id is not None or copy.source not in lookups:
        return copy
    try:
        found = await lookups[copy.source](copy.id)
    except Exception as e:                        # one copy unreachable: the rest still go
        print(f"skipped {copy.source} {copy.id}: {type(e).__name__}")
        found = None
    await asyncio.sleep(pause)
    if found is None:
        return copy
    return copy.model_copy(update = {f: getattr(copy, f) if getattr(copy, f) is not None else getattr(found, f)
                                     for f in IDENTITY})


async def refresh(pool, apply: bool, limit: int | None = None, lookups = LOOKUPS, fetch_release = None,
                  pause: float = PAUSE_SECONDS) -> list[str]:
    """Each song whose cover changes, as "title by artists: release (kind, year)", written when [apply]."""
    async with pool.connection() as conn:
        songs = await kept_songs(conn, limit)
    changes = []
    for song in songs:
        async with pool.connection() as conn:
            stored = [_stored_listing(r) for r in await (await conn.execute(
                "SELECT * FROM listings WHERE song_id = %s ORDER BY source, source_id", [song["id"]])).fetchall()]
        copies = [await with_identity(c, lookups, pause) for c in stored]
        if apply:
            async with pool.connection() as conn:
                for before, now in zip(stored, copies):
                    if now is not before:
                        await conn.execute(
                            """UPDATE listings SET artist_ids = COALESCE(artist_ids, %s), album_id = COALESCE(album_id, %s),
                                                   kind = COALESCE(kind, %s), year = COALESCE(year, %s)
                                WHERE source = %s AND source_id = %s""",
                            [now.artist_ids, now.album_id, now.kind, now.year, now.source, now.id])
        release = await releases.refresh_cover(pool, song["id"], fetch_release, copies = copies, write = apply)
        if release is not None:
            changes.append(f"{song['title']} by {', '.join(song['artists'])}: {release.title} "
                           f"({release.kind}, {release.year})")
    return changes


async def main(apply: bool, limit: int | None) -> None:
    pool = db.make_pool(db.DATABASE_URL)
    await pool.open()
    try:
        changes = await refresh(pool, apply, limit)
    finally:
        await pool.close()
    print("\n".join(changes))
    print(f"{len(changes)} {'changed' if apply else 'would change (run with --apply)'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="write the changes (without it, only list them)")
    parser.add_argument("--limit", type=int, help="only the most recently kept songs, this many")
    args = parser.parse_args()
    asyncio.run(main(args.apply, args.limit))
