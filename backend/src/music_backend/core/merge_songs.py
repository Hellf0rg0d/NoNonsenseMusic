"""Merge the songs stored more than once, as resolve_song now finds them (migrations/0007).

Songs were found by their whole title until 24 Oct, so a recording each source spells differently was stored once per
spelling: ZEZE "(feat. Travis Scott & Offset)" and "(feat. Offset & Travis Scott)". Songs sharing a core title are
compared as resolve_song compares them: the oldest is the centre, and each song that is the same recording as it is
merged into it (library.merge_songs: recorded, and library.split_song undoes one). One core title at a time, under the
lock resolve_song takes, so a like arriving meanwhile waits.

    uv run python -m music_backend.core.merge_songs            # lists what would be merged
    uv run python -m music_backend.core.merge_songs --apply    # merges them
"""
import argparse
import asyncio

from music_backend.core import db
from music_backend.services import library
from music_backend.services.matching import same_recording

WHY = "stored once per spelling before 24 Oct (core/merge_songs.py)"


def centres(songs: list) -> list[tuple]:
    """(centre, the songs merged into it), oldest first: each song left joins the oldest one it is the same recording
    as, if that is the centre; compared with the centre only, so 200 s, 204 s and 208 s never chain into one."""
    merges, left = [], list(songs)
    while left:
        centre, *rest = left
        same = [s for s in rest if same_recording(centre, s)]
        if same:
            merges.append((centre, same))
        left = [s for s in rest if s not in same]
    return merges


async def merge(pool, apply: bool) -> list[str]:
    async with pool.connection() as conn:
        await library.fill_core_titles(conn)
        cores = [r["core_title"] for r in await (await conn.execute(
            "SELECT core_title FROM songs GROUP BY core_title HAVING count(*) > 1 ORDER BY core_title")).fetchall()]
    changes = []
    for core in cores:
        async with pool.connection() as conn, conn.transaction():
            await conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", [core])
            songs = await library.recordings(conn, "s.core_title = %s", [core])
            for centre, same in centres(songs):
                for song in same:
                    changes.append(f"{song.title!r} by {', '.join(song.artists)} ({song.duration} s) "
                                   f"-> {centre.title!r} ({centre.duration} s)")
                    if apply:
                        await library.merge_songs(conn, song.id, centre.id, WHY)
    return changes


async def main(apply: bool) -> None:
    pool = db.make_pool(db.DATABASE_URL)
    await pool.open()
    try:
        changes = await merge(pool, apply)
    finally:
        await pool.close()
    print("\n".join(changes))
    print(f"{len(changes)} {'merged' if apply else 'would be merged (run with --apply)'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="merge them (without it, only list them)")
    asyncio.run(main(parser.parse_args().apply))
