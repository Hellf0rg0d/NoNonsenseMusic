"""Cache audio URLs, lyrics and Genius notes.

ListingURLCache serves one audio URL per listing from memory and the listing_urls table, with single-flight
lookups and a per-source pause after a bot check. LyricsCache and GeniusCache keep per-song replies in the
lyrics and genius tables.
"""

from collections import deque, OrderedDict
from datetime import datetime, timedelta, timezone
import asyncio
import logging
import time

from psycopg.types.json import Jsonb

from music_backend.services import genius, lyrics
from music_backend.models import GeniusRequest, GeniusResponse, LyricsRequest, LyricsResponse
from music_backend.core.settings import settings
from music_backend.sources import SongNotFound, SourceBlocked, SourceUnavailable

logger = logging.getLogger(__name__)


def single_flight(running: dict, key, work) -> asyncio.Task:
    """Return the lookup already running for `key`, or start one ("single-flight").

    The task is created and registered at once, before the next await, so a second caller finds it and waits
    instead of starting another. `work` builds the lookup: a function returning a coroutine. When the lookup
    ends, worked or failed, the key leaves `running`, so the next caller starts afresh. Both caches use it.
    """
    task = running.get(key)
    if task is None:
        task = asyncio.create_task(_run_once(running, key, work))
        running[key] = task
    return task


async def _run_once(running: dict, key, work):
    try:
        return await work()
    finally:
        del running[key]


class ListingURLCache:
    """Store audio URLs per listing (source, song_id) in two levels: memory and the listing_urls table.
    Both drop the least recently used entry when full.

    Call it to get a URL:   url = await cache(source, song_id)
    It answers from memory or the table when the cached URL is still good, and otherwise fetches, stores
    and returns a new one.
    """

    def __init__(self, sources: dict, pool):
        self.cache = OrderedDict()
        self.sources = sources            # SOURCES from main.py: the single list of sources, not a copy
        self.max_size_in_memory = settings.cache_max_size_in_memory
        self.max_size_in_db = settings.cache_max_size_in_db
        self.pool = pool
        self.running = {}
        # Backoff ("circuit breaker"), per source: a bot check blocks the server's IP, not one song.
        self.blocked_until: dict[str, float] = {}   # source -> Unix time until which the source is not asked
        self.strikes: dict[str, int] = {}           # source -> blocking episodes in a row; each one doubles the pause
        # Prefetch: (source, source_id) pairs waiting for a worker, held per user in arrival order. A worker takes
        # one listing from the user at the front, then sends that user to the back, so different users' prefetches
        # take turns. A queue per user is needed because one shared queue let a new list from any user wipe out
        # every other user's waiting list.
        self.waiting: dict[object, deque[tuple[str, str]]] = {}
        self._something_waits = asyncio.Event()

    async def _db_hit(self, source: str, song_id: str) -> None:
        # the table's own "recently used" mark: the trim in _set_db drops the oldest hit_at first
        async with self.pool.connection() as conn:
            await conn.execute("UPDATE listing_urls SET hit_at = now() WHERE source = %s AND source_id = %s",
                               [source, song_id])

    def _cache_hit(self, source: str, song_id: str) -> None:
        # plain def: it awaits nothing, memory only
        self.cache.move_to_end((source, song_id))

    async def _get_db(self, source: str, song_id: str) -> str | None:
        """Return the stored URL without marking it used (the prefetch worker's check: a prefetch is not a use)."""
        async with self.pool.connection() as conn:
            row = await (await conn.execute("SELECT url FROM listing_urls WHERE source = %s AND source_id = %s",
                                            [source, song_id])).fetchone()
        return None if row is None else row["url"]

    async def _take_db(self, source: str, song_id: str) -> str | None:
        """Return the stored URL and mark it used in one statement.

        A separate SELECT then UPDATE would take two round trips. An expired row is marked too: the fresh
        fetch that follows overwrites it anyway.
        """
        async with self.pool.connection() as conn:
            row = await (await conn.execute(
                "UPDATE listing_urls SET hit_at = now() WHERE source = %s AND source_id = %s RETURNING url",
                [source, song_id])).fetchone()
        return None if row is None else row["url"]

    async def _set_db(self, source: str, song_id: str, url: str) -> None:
        # One upsert then the trim, in a single block so both commit together. Two statements sent at once
        # raced and crashed with UniqueViolation.
        async with self.pool.connection() as conn:
            await conn.execute(
                """INSERT INTO listing_urls (source, source_id, url) VALUES (%s, %s, %s)
                   ON CONFLICT (source, source_id) DO UPDATE SET
                       url        = EXCLUDED.url,
                       fetched_at = CASE WHEN listing_urls.url <> EXCLUDED.url THEN now() ELSE listing_urls.fetched_at END,
                       hit_at     = now()""",
                [source, song_id, url],
            )
            await conn.execute(
                """DELETE FROM listing_urls WHERE (source, source_id) IN (
                       SELECT source, source_id FROM listing_urls ORDER BY hit_at DESC OFFSET %s)""",
                [self.max_size_in_db],
            )

    async def get(self, source: str, song_id: str) -> str | None:
        """Return one URL or None: memory first, then the table.

        Every hit marks the row used (hit_at), so the trim drops the least recently used; a table hit also
        copies the URL into memory. A hit adds no row: one statement reads and marks it (UPDATE … RETURNING),
        and the trim runs only in `set`, so a hit cannot grow the table. Writing on every hit instead takes
        two statements per hit (an upsert and the trim's DELETE): 600 statements for 300 hits. The prefetch
        worker checks through `_has_fresh`, which marks nothing.
        """
        url = self.cache.get((source, song_id))
        if url is not None:
            if self.sources[source].is_expired(url):
                return None
            self._cache_hit(source, song_id)
            await self._db_hit(source, song_id)
            return url
        url = await self._take_db(source, song_id)              # marked used: the trim keeps the most recently used
        if url is None or self.sources[source].is_expired(url):
            return None
        self._remember(source, song_id, url)
        return url

    async def set(self, source: str, song_id: str, url: str) -> None:
        """Store a freshly fetched URL at both levels.

        The upsert sets hit_at; only this path adds a row, so the trim runs only here.
        """
        self._remember(source, song_id, url)
        await self._set_db(source, song_id, url)

    def _remember(self, source: str, song_id: str, url: str) -> None:
        # memory: store as the most recently used, and drop the least recently used past the limit
        self.cache[(source, song_id)] = url
        self._cache_hit(source, song_id)
        if len(self.cache) > self.max_size_in_memory:
            self.cache.popitem(last=False)

    async def __call__(self, source: str, song_id: str, serve_fresh: bool = False) -> str:
        """Return a URL for the listing: fetch when there is no cached one, when serve_fresh is set, or when
        it expires soon; otherwise return the cached one."""
        url = None if serve_fresh else await self.get(source, song_id)
        if url is None:
            # wait for the lookup, with its URL or its error. shield: cancelling this request (the song was
            # skipped) ends only its own wait; the lookup keeps running for other waiters and fills the cache
            url = await asyncio.shield(self._start_lookup(source, song_id))
        return url

    def _start_lookup(self, source: str, song_id: str) -> asyncio.Task:
        """Single-flight per listing: a second request for a listing already being fetched waits for that fetch."""
        return single_flight(self.running, (source, song_id), lambda: self._lookup(source, song_id))

    async def _lookup(self, source: str, song_id: str) -> str:
        """Fetch, store and return the URL. The task runs once per listing at a time (single-flight)."""
        # refuse at once, with no request sent: a refusal during a pause adds no strike (the source was not asked)
        self._refuse_if_paused(source)
        try:
            # SongNotFound / SourceUnavailable pass straight through, so a failure is never stored
            url = await self.sources[source].get_song_url(song_id)
        except SourceBlocked:
            self._strike(source)        # the source said "blocked": a strike (one per episode), then pass the error on
            raise
        # a successful answer resets the count so the next block starts from the short pause, except during a
        # pause: this lookup began before the block started (no new one can start), so its answer says nothing
        # about the source's current state
        if not self._is_paused(source):
            self.strikes[source] = 0
        await self.set(source, song_id, url)
        return url

    def _refuse_if_paused(self, source: str) -> None:
        """Raise SourceBlocked during a source's pause, before any request goes to the source."""
        if self._is_paused(source):
            until = time.strftime('%H:%M:%S', time.localtime(self.blocked_until[source]))
            raise SourceBlocked(f"{source} is paused after a bot check until {until}")

    def _is_paused(self, source: str) -> bool:
        """Return whether the source's pause is in effect (a source never blocked: no).

        The single check, used everywhere.
        """
        return self.blocked_until.get(source, 0) > time.time()

    def _strike(self, source: str) -> None:
        """Record a bot check from the source: one more blocking episode in a row, so pause = START x
        2^(strikes - 1), at most MAX. A bot check during a pause belongs to the episode already running:
        lookups under way when the block began all return blocked, and counting each one would pause for
        16 min at four replies rather than 2. Such a reply adds no strike and does not lengthen the pause."""
        if self._is_paused(source):
            return
        self.strikes[source] = self.strikes.get(source, 0) + 1
        minutes = min(settings.backoff_max_minutes, settings.backoff_start_minutes * 2 ** (self.strikes[source] - 1))
        self.blocked_until[source] = time.time() + minutes * 60
        logger.warning("%s: bot check #%d in a row, asking it nothing for %.0f min", source, self.strikes[source], minutes)

    async def _has_fresh(self, source: str, song_id: str) -> bool:
        """Return whether a good URL is cached, marking nothing. The prefetch worker checks this way: using
        `get` would mark the row used, so "least recently used" would mean "least recently prefetched"
        (up to 10 UPDATEs per song change)."""
        url = self.cache.get((source, song_id))                # a plain dict read: the order is left as it is
        if url is None:
            url = await self._get_db(source, song_id)
        return url is not None and not self.sources[source].is_expired(url)

    def prefetch(self, user_id, listings) -> None:
        """Replace this user's waiting list with their newest one and send them to the back of the line.

        Lookups already running finish; other users' lists are untouched.
        """
        self.waiting.pop(user_id, None)
        if listings:
            self.waiting[user_id] = deque((listing.source, listing.source_id) for listing in listings)
            self._something_waits.set()                                  # wakes the free workers

    def _next_waiting(self) -> tuple[str, str]:
        """Return one listing from the user at the front; that user goes to the back, or leaves when their
        list is done."""
        user_id, listings = next(iter(self.waiting.items()))
        listing = listings.popleft()
        del self.waiting[user_id]
        if listings:
            self.waiting[user_id] = listings
        return listing

    async def prefetch_worker(self) -> None:
        """Run one prefetch worker (main.py's lifespan starts several): take the next waiting listing and
        look it up, unless it is cached or already being looked up. One lookup at a time per worker, so N
        workers mean at most N prefetch lookups at once: yt-dlp shares its threads with the user's clicks."""
        while True:
            while not self.waiting:                                      # free: asleep here until a list arrives
                self._something_waits.clear()
                await self._something_waits.wait()
            source, song_id = self._next_waiting()
            try:
                if (source, song_id) in self.running or await self._has_fresh(source, song_id):
                    continue                                             # running (it fills the cache anyway) or cached
                await asyncio.shield(self._start_lookup(source, song_id))
            except (SongNotFound, SourceUnavailable) as e:
                # expected: a song that is gone, a network blip, a source in its pause. One line at info
                logger.info("prefetch %s %s: %s", source, song_id, e)
            except Exception:
                # a bug: log the traceback, but keep this worker alive (an uncaught error would end its loop)
                logger.exception("prefetch %s %s failed", source, song_id)


class LyricsCache:
    """Store lyrics replies per song in the lyrics table.

    Lyrics differ from ListingURLCache: they are kept per song, not per listing, never go stale when timed,
    and need no memory level, backoff or workers. Only single-flight is shared (`single_flight`, above).

    Call it to get lyrics:   reply = await lyrics_cache(song)
    Timed lyrics are kept for good. Plain or empty ones are kept for settings.lyrics_recheck_days, and only
    when every source answered: if one failed, it may have had better, so the next request asks again.
    """

    def __init__(self, pool):
        self.pool = pool
        self.running: dict[tuple, asyncio.Task] = {}     # single-flight, as in ListingURLCache: one lookup per song

    async def __call__(self, song: LyricsRequest) -> LyricsResponse:
        reply = await self.get(song)
        if reply is None:
            # shield: a request that gives up (the app closed Lyrics) does not cancel a lookup another request shares
            reply = await asyncio.shield(self._start_lookup(song))
        return reply

    def _start_lookup(self, song: LyricsRequest) -> asyncio.Task:
        return single_flight(self.running, key(song), lambda: self._lookup(song))

    async def _lookup(self, song: LyricsRequest) -> LyricsResponse:
        reply, every_source_answered = await lyrics.find_lyrics(song)
        if reply.synced or every_source_answered:
            await self.set(song, reply)
        return reply

    async def get(self, song: LyricsRequest) -> LyricsResponse | None:
        async with self.pool.connection() as conn:
            cur = await conn.execute(
                """SELECT reply, fetched_at FROM lyrics
                   WHERE song_name = %s AND artist_name = %s AND song_duration = %s AND youtube_id = %s""", key(song))
            row = await cur.fetchone()
        if row is None:
            return None
        reply = LyricsResponse.model_validate(row["reply"])
        recheck_after = row["fetched_at"] + timedelta(days=settings.lyrics_recheck_days)
        if not reply.synced and datetime.now(timezone.utc) > recheck_after:
            return None                          # plain or empty, and old: a source may have them later
        return reply

    async def set(self, song: LyricsRequest, reply: LyricsResponse) -> None:
        async with self.pool.connection() as conn:
            await conn.execute(
                """INSERT INTO lyrics (song_name, artist_name, song_duration, youtube_id, reply) VALUES (%s, %s, %s, %s, %s)
                   ON CONFLICT (song_name, artist_name, song_duration, youtube_id) DO UPDATE SET
                       reply = EXCLUDED.reply, fetched_at = now()""",
                [*key(song), Jsonb(reply.model_dump())],
            )


class GeniusCache:
    """Store Genius notes per song in the genius table, shared by every user: fetched once, then again after
    settings.genius_recheck_days. Single-flight as in the other caches. A failure (Genius unreachable) is
    never stored.

    Call it:   reply = await genius_cache(song)        # GeniusUnavailable when Genius cannot be asked
    """

    def __init__(self, pool):
        self.pool = pool
        self.running: dict[tuple, asyncio.Task] = {}

    async def __call__(self, song: GeniusRequest) -> GeniusResponse:
        reply = await self.get(song)
        if reply is None:
            key = (song.song_name, song.artist_name)
            reply = await asyncio.shield(single_flight(self.running, key, lambda: self._lookup(song)))
        return reply

    async def _lookup(self, song: GeniusRequest) -> GeniusResponse:
        reply = await genius.find_notes(song)
        async with self.pool.connection() as conn:
            await conn.execute(
                """INSERT INTO genius (song_name, artist_name, reply) VALUES (%s, %s, %s)
                   ON CONFLICT (song_name, artist_name) DO UPDATE SET reply = EXCLUDED.reply, fetched_at = now()""",
                [song.song_name, song.artist_name, Jsonb(reply.model_dump())])
        return reply

    async def get(self, song: GeniusRequest) -> GeniusResponse | None:
        async with self.pool.connection() as conn:
            row = await (await conn.execute(
                "SELECT reply, fetched_at FROM genius WHERE song_name = %s AND artist_name = %s",
                [song.song_name, song.artist_name])).fetchone()
        if row is None or datetime.now(timezone.utc) > row["fetched_at"] + timedelta(days=settings.genius_recheck_days):
            return None
        return GeniusResponse.model_validate(row["reply"])


def key(song: LyricsRequest) -> tuple[str, str, int, str]:
    """Return one song as the app asks for it. With and without a YouTube copy are two entries: the answers
    can differ."""
    return song.song_name, song.artist_name, song.song_duration, song.youtube_id or ""
