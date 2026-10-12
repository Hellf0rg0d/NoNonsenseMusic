"""Limit how often one address, one address-and-username pair, or one account may act.

Per address (IP): signing in, signing up and password recovery, the routes open to guessing. Sign-in and recovery
also use an address-and-username key: it slows repeated guesses without letting strangers lock a username from a
different address. Per account, after sign-in: the routes
that make this server ask YouTube, JioSaavn, LRCLIB or Genius, so one account cannot make the sources block the
server for everyone.

Each key holds a sliding window in this process's memory: one server needs no Redis, and a restart forgets the
counts. Addresses are kept only as a truncated SHA-256, in memory, and are never logged. Requests from the machine
itself (127.0.0.1, ::1) are not counted, so a local server and the test servers run unlimited. A hosted server sits
behind a proxy that passes the real address in X-Forwarded-For: client_address believes that header only from a peer
listed in settings.trusted_proxies, so a client cannot choose its own address (or claim to be local) by sending it.
An IPv6 client is counted by its /64, the smallest block one subscriber normally holds, since one person can otherwise
rotate through billions of addresses. Over a limit: 429, with Retry-After in seconds.
"""
import hashlib
import ipaddress
import time
from collections import deque
from functools import lru_cache

from fastapi import HTTPException, Request

from music_backend.core.settings import settings

# action → (allowed hits, window length in seconds)
LIMITS: dict[str, tuple[int, int]] = {
    "signin_address": (10, 60),
    "signup_address": (5, 3600),
    "recover_address": (5, 900),
    "signin_identity": (20, 3600),
    "recover_identity": (10, 3600),
    "search": (60, 60),
    "lyrics": (60, 60),
    "genius": (30, 60),
    "prefetch": (60, 60),
    "play": (120, 60),
    "play_fresh": (20, 60),             # /play?serve_fresh=true: always asks the source, never the cache
    "friends": (30, 60),
    "friend_request": (20, 60),
    "notifications": (60, 60),          # /ws-ticket: caps how fast tickets can be minted
    "album": (60, 60),                  # GET /album: each one asks a source for a full track list
    "artist": (60, 60),                 # GET /artist: each one may fan out to several album pages
    "radio": (30, 60),                  # POST /radio: each one asks a source for a station batch
    "jam": (20, 60),                    # POST /jam and /jam/join: opening rooms, not the controls inside them
    "recovery_codes": (5, 900),         # replacing codes is sensitive even after a password check
    "playlist_create": (30, 3600),      # POST /playlists: each one adds a row for good
    "share": (30, 3600),
    "import": (10, 3600),               # POST /import/spotify: each one searches every song of a library                # PUT /playlists/{id}/members: each new member sends an invite notification
}
# headers a proxy sets; a request from this machine that carries one went through a proxy on this machine
PROXY_HEADERS = ("x-forwarded-for", "forwarded", "x-real-ip")


@lru_cache
def _proxy_networks(text: str) -> tuple:
    return tuple(ipaddress.ip_network(part.strip(), strict=False) for part in text.split(",") if part.strip())


def _parse(host: str):
    """Return the address as an ip_address (an IPv4-mapped IPv6 one as its IPv4), or None when it is not an address."""
    try:
        ip = ipaddress.ip_address(host.strip())
    except ValueError:
        return None
    return (ip.ipv4_mapped or ip) if ip.version == 6 else ip


def client_address(request: Request) -> tuple[str, bool]:
    """Return (the caller's address, whether it arrived through a proxy this server trusts).

    A direct peer that is not listed in settings.trusted_proxies is the caller, and X-Forwarded-For is ignored: any
    client can send that header. From a listed peer the header is read from its right, which is the end the nearest
    proxy appended to, skipping proxies that are listed too; the first other address is the caller. Entries to its left
    are whatever the caller sent. A header with nothing usable leaves the proxy itself as the caller.
    """
    peer = request.client.host if request.client else ""
    peer_ip = _parse(peer)
    proxies = _proxy_networks(settings.trusted_proxies)
    if peer_ip is None or not any(peer_ip in net for net in proxies):
        return peer, False
    forwarded = ",".join(request.headers.getlist("x-forwarded-for"))
    for entry in reversed([e.strip() for e in forwarded.split(",") if e.strip()]):
        ip = _parse(entry)
        if ip is None:
            break                                   # not an address: do not guess past it
        if not any(ip in net for net in proxies):
            return str(ip), True
    return peer, True


def is_local(request: Request) -> bool:
    """Return whether the request comes from this machine itself, with no proxy in between.

    Behind a proxy on the same machine every connection arrives from 127.0.0.1, so the peer alone proves nothing: a
    listed proxy, or a proxy header on a connection from this machine, means the caller is someone else.
    """
    address, via_proxy = client_address(request)
    ip = _parse(address)
    if via_proxy or ip is None or not ip.is_loopback:
        return False
    return not any(name in request.headers for name in PROXY_HEADERS)


def _key(request: Request) -> str:
    """The caller as a truncated hash, the one key per address: an IPv6 caller by its /64."""
    address, _ = client_address(request)
    ip = _parse(address)
    if ip is not None and ip.version == 6:
        address = str(ipaddress.ip_network(f"{ip}/64", strict=False))
    return hashlib.sha256(address.encode()).hexdigest()[:16]


class Limiter:
    def __init__(self) -> None:
        self._hits: dict[tuple[str, str], deque[float]] = {}
        self._checks = 0

    def check(self, action: str, who: str) -> None:
        """Count one `action` by `who` and raise 429 when its window is full.

        Hits older than the window are dropped first, so the limit covers any span of
        `window` seconds rather than a fixed bucket.
        """
        count, window = LIMITS[action]
        now = time.monotonic()
        hits = self._hits.setdefault((action, who), deque())
        while hits and hits[0] <= now - window:
            hits.popleft()
        if len(hits) >= count:
            # Round up so the retry lands after the oldest hit leaves the window.
            wait = int(hits[0] + window - now) + 1
            raise HTTPException(status_code=429, detail=f"Too many attempts. Try again in {wait} s.",
                                headers={"Retry-After": str(wait)})
        hits.append(now)
        self._checks += 1
        # One sweep per 1000 checks keeps the cleanup off the hot path.
        if self._checks % 1000 == 0:
            self._forget_old(now)

    def check_address(self, request: Request, action: str) -> None:
        """Count the request against the caller's address, leaving local requests uncounted."""
        if is_local(request):
            return
        self.check(action, _key(request))

    def check_address_and_username(self, request: Request, action: str, username: str) -> None:
        """Limit one credential target from one address, without a global username lockout.

        This intentionally counts successful attempts too. The independent address limit still
        bounds broad credential stuffing, while this key prevents one account being locked by a
        stranger who rotates through other addresses.
        """
        if is_local(request):
            return
        self.check(action, f"{_key(request)}:{username.casefold()}")

    def _forget_old(self, now: float) -> None:
        """Drop keys with no hit inside the longest window, so memory does not grow with every address seen."""
        longest = max(w for _, w in LIMITS.values())
        for key in [k for k, hits in self._hits.items() if not hits or hits[-1] <= now - longest]:
            del self._hits[key]
