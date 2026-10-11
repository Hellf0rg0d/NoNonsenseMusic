"""Read settings once from backend/.env. A variable set in the real environment wins over the file.

Use it anywhere:   from music_backend.core.settings import settings   ->   settings.cache_max_size
Add a setting:     a field here, plus the same name in UPPER_CASE in .env and .env.example.
A key in .env that has no field here stops the server at startup (that catches typos).
"""
import ipaddress
from pathlib import Path

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# an absolute path, so .env is found whichever folder the server is started from
ENV_FILE = Path(__file__).resolve().parents[3] / ".env"   # backend/.env, reached from backend/src/music_backend/core/


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=ENV_FILE,
        env_parse_none_str="None",   # KEY="None" means Python None
        env_ignore_empty=True,       # KEY= (nothing) means "not set": the default below is used
    )

    # no host or password: connect over the local socket as the current macOS user
    database_url: str = "postgresql:///music"
    # minutes: a cached YouTube URL this close to its expire= time is fetched again
    youtube_cache_expiry_threshold: int = 30
    # prefetch workers: at most this many prefetch lookups at once (yt-dlp shares its threads with the user's clicks)
    num_prefetch_workers: int = 4
    # minutes: after a source's first bot check, ask it nothing for this long; each bot check in a row doubles it
    backoff_start_minutes: float = 2
    # minutes: the pause never grows past this, so a lifted block is noticed within this long
    backoff_max_minutes: float = 60
    # entries in the cache's memory before the least recently used one is dropped
    cache_max_size_in_memory: int = 3000
    # rows in the listing_urls table: after each write, the oldest-fetched beyond this are deleted
    cache_max_size_in_db: int = 6000
    # days: plain or empty lyrics are asked for again after this long (timed lyrics are kept for good)
    lyrics_recheck_days: float = 7
    # Genius notes (experimental): the official API's token, used only when the website's own API fails.
    # None means no fallback; the official API answers 401 without a token. Get one at genius.com/api-clients
    genius_access_token: str | None = None
    # JioSaavn sends each song's audio address encrypted. The key is not part of this repository; without it,
    # JioSaavn still answers searches, and its copies fail to play, so the apps play another copy
    jiosaavn_key: str | None = None
    # days: a song's Genius notes are asked for again after this long (people keep adding notes)
    genius_recheck_days: float = 30

    # days: a session (one signed-in device) not used for this long ends; each use pushes the end forward
    session_days: int = 30
    # minutes: a session's end is pushed forward at most this often, so most requests only read their session
    # instead of writing it (a write on every request was the cost; a 30-day window does not care about an hour)
    session_slide_minutes: int = 60
    session_cleanup_hours: int = 6       # how often expired sessions are deleted

    # Reverse proxies whose X-Forwarded-For header is believed, as comma-separated IPs or CIDR ranges
    # ("10.0.0.0/8,203.0.113.7"). Empty (the default) believes no header: every request is attributed to the address
    # it arrived from, which is right for a server reached directly, such as the one on the user's own Mac.
    # Behind a proxy the setting is required: without it every user shares the proxy's address, so one person
    # exhausts the limits of all, and a proxy on the same machine makes every request look local.
    # Render: its proxies forward X-Forwarded-For, so list the addresses they connect from (DEPLOY.md). The client is
    # the rightmost X-Forwarded-For entry that is not itself listed: a listed peer can claim any address, so never
    # list a range an outside client can connect from.
    trusted_proxies: str = ""

    @field_validator("trusted_proxies")
    @classmethod
    def _valid_proxies(cls, value: str) -> str:
        # fail at startup on a typo, instead of silently trusting nobody (or the wrong range) at the first request
        for part in value.split(","):
            if part.strip():
                ipaddress.ip_network(part.strip(), strict=False)
        return value


settings = Settings()
