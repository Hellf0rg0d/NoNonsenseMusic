"""A song's cover does not depend on the order the sources list its copies in, and a stored song keeps its cover."""
import itertools
import uuid

import pytest

from music_backend.models import Listing
from music_backend.services import library
from music_backend.services.matching import pick_best, pick_cover



def copy(source, id, album, image, popularity=None, title="Gummo"):
    return Listing(source=source, id=id, title=title, artists=["Alex"], album=album, duration=157,
                   popularity=popularity, image=image)


# JioSaavn lists one recording's releases with the same play count and length: only the order differs
RELEASES = [copy("jiosaavn", "js-hits", "Greatest Hits", "https://img/hits.jpg", 208254),
            copy("jiosaavn", "js-single", "Gummo", "https://img/single.jpg", 208254),
            copy("jiosaavn", "js-album", "Day69", "https://img/day69.jpg", 208254)]


def test_best_copy_and_cover_ignore_the_order_of_the_copies():
    bests = {pick_best(list(order)).id for order in itertools.permutations(RELEASES)}
    covers = {pick_cover(list(order)) for order in itertools.permutations(RELEASES)}
    assert len(bests) == 1 and len(covers) == 1


def test_cover_prefers_youtube_music_and_skips_copies_without_art():
    ytm = copy("ytmusic", "yt-1", "Gummo", "https://img/ytm.jpg", 499_000_000)
    assert pick_cover(RELEASES + [ytm]) == "https://img/ytm.jpg"
    assert pick_cover([copy("jiosaavn", "x", "Gummo", None)]) is None


def fresh(listings):
    """The same copies under a title and ids no earlier run stored."""
    tag = uuid.uuid4().hex[:8]
    return [l.model_copy(update={"id": f"{l.id}-{tag}", "title": f"Gummo {tag}"}) for l in listings]


@pytest.mark.anyio
async def test_a_stored_song_keeps_its_cover_when_more_copies_are_linked(pool, user_id):
    RELEASES_ = fresh(RELEASES + [copy("ytmusic", "yt-1", "Gummo", "https://img/ytm.jpg", 499_000_000)])
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, RELEASES_[:1])
        await library.like(conn, user_id, song_id)
        before = (await library.liked_songs(conn, user_id))[0].image
        # a later search links a YouTube Music copy, which pick_cover would prefer for a new song
        await library.resolve_song(conn, [RELEASES_[0], RELEASES_[3]])
        after = (await library.liked_songs(conn, user_id))[0]
    assert before == "https://img/hits.jpg"
    assert after.image == before and len(after.listings) == 2


@pytest.mark.anyio
async def test_a_song_stored_before_covers_gets_one_once(pool, user_id):
    releases = fresh(RELEASES)
    async with pool.connection() as conn:
        song_id = await library.resolve_song(conn, releases)
        await conn.execute("UPDATE songs SET image = NULL WHERE id = %s", [song_id])
        await library.like(conn, user_id, song_id)
        first = (await library.liked_songs(conn, user_id))[0].image
        stored = (await (await conn.execute("SELECT image FROM songs WHERE id = %s", [song_id])).fetchone())["image"]
    assert first == pick_cover(releases) and stored == first
