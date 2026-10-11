"""Remember the listings this server itself returned, so a client cannot write its own version of one.

A song's title, artists, duration and cover are stored once and shown to every user who meets it. If the stored copy
came from the request that first liked or played the song, any account could publish a made-up title or image for a
real (source, id) to everyone. So the copy written is always one the server holds: either one it handed out recently
(search, album, artist and radio replies, remembered here) or one already stored in the listings table.

The record is in this process's memory and bounded: entries last 6 hours and the oldest go first past the cap. Memory
is the cheap choice. A table written on every search would add a database write per result for data that is only
needed for the minutes between a search and a like. The cost is that a restart (a deploy) forgets what was served,
and the app must then search again before it can store a song it has not stored before; a song that is already
stored keeps working, because its row is the other source of truth.
"""
import time
from collections import OrderedDict
from collections.abc import Iterable

from music_backend.models import Listing

TTL_SECONDS = 6 * 3600
MAX_ENTRIES = 50_000


class ServedListings:
    """Map (source, id) to the listing as the server returned it, for TTL_SECONDS, at most MAX_ENTRIES at once."""

    def __init__(self, ttl: float = TTL_SECONDS, cap: int = MAX_ENTRIES) -> None:
        self.ttl, self.cap = ttl, cap
        # Insertion order is expiry order: remembering a key again moves it to the end with a new expiry, so the
        # front is always the oldest entry, whether it leaves by age or by the cap.
        self._entries: OrderedDict[tuple[str, str], tuple[float, Listing]] = OrderedDict()

    def remember(self, listings: Iterable[Listing]) -> None:
        """Record listings the server is about to return. A newer copy replaces an older one."""
        now = time.monotonic()
        for listing in listings:
            key = (listing.source, listing.id)
            self._entries.pop(key, None)
            self._entries[key] = (now + self.ttl, listing.model_copy())
        while self._entries:
            oldest = next(iter(self._entries))
            if len(self._entries) <= self.cap and self._entries[oldest][0] > now:
                break
            del self._entries[oldest]

    def get(self, source: str, listing_id: str) -> Listing | None:
        """Return the listing the server returned for this key, or None when it never did or the entry has expired."""
        entry = self._entries.get((source, listing_id))
        if entry is None:
            return None
        if entry[0] <= time.monotonic():
            del self._entries[(source, listing_id)]
            return None
        return entry[1]
