"""Bring a library in from Spotify or YouTube.

The app reads the file on the device (Exportify's CSV, Spotify's own data export, a Google Takeout CSV) and sends only
each song's title, artists and length, or its YouTube video id; a YouTube playlist link is read here. A YouTube song is
found by its id, and joined with the same song's other copies when a search finds them. Here each one is searched on the music sources, the result that agrees on title, artist and
length is kept, and it is liked or added to a new playlist. A song with no such result is counted as not found rather
than guessed: a wrong song in your library is worse than a missing one.

One song at a time, with a pause between searches: a library of 1,000 songs is 1,000 searches, and asked all at once
the sources would block this server for everyone. Progress lives in this process's memory, as jam rooms do: a restart
ends a running import, and what it already added stays.
"""
import asyncio
import logging
import re
import unicodedata
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from uuid import UUID, uuid4

from psycopg import errors

from music_backend.models import Listing, Song, SpotifyImportGroup, SpotifyImportSong, SpotifyImportStatus
from music_backend.services import library
from music_backend.services.matching import to_song

logger = logging.getLogger(__name__)

PAUSE_SECONDS = 0.8          # between two searches
DURATION_SLACK = 8           # seconds a copy's length may differ from Spotify's (other masters, silence at the end)


# ---------- matching ----------

# "Song - Remastered 2011" is written "Song (Remastered 2011)" elsewhere: the dash form becomes the bracket form first
_DASHED = re.compile(r"\s+-\s+(.*)$")
_BRACKETS = re.compile(r"\s*[\(\[]([^)\]]*)[\)\]]")
# labels that leave the recording as it is; "Remix", "Live", "Acoustic" name another recording and stay in the title
# ("Despacito - Remix" matched the original before, 12 Oct)
_SAME_RECORDING = re.compile(r"\b(feat|ft|with|from|remaster(ed)?|version|edit|mono|stereo|bonus|single|deluxe|explicit"
                             r"|clean|original)\b", re.IGNORECASE)


def _plain(text: str) -> str:
    """Lower case, accents dropped, punctuation as spaces: "Despacito (feat. Justin Bieber)" and "despacito" meet."""
    # only the accent marks go: an ASCII-only filter would empty a title in Devanagari, and any two would then match
    text = "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))
    return " ".join(re.sub(r"[^\w\s]", " ", text.lower()).split())


def core_title(title: str) -> str:
    """The title without labels that leave the recording as it is ("(feat. X)", "- Remastered 2011", "(From "Film")").
    Other labels stay as words: "Song - Remix" is "song remix", another song than "Song"."""
    bracketed = _DASHED.sub(r" (\1)", title)
    kept = _BRACKETS.sub(lambda m: "" if _SAME_RECORDING.search(m.group(1)) else f" {m.group(1)}", bracketed)
    return _plain(kept) or _plain(title)


def same_artist(a: str, b: str) -> bool:
    """One artist written two ways: one name inside the other ("Arijit Singh", "Arijit Singh & Shreya"), the same words in
    another order ("Sukh-E Muzical Doctorz", "Muzical Doctorz Sukh-E"), or other spacing ("Sidhu Moose Wala", "Sidhu
    Moosewala"). Four of 140 real songs were missed for these two (12 Oct)."""
    x, y = _plain(a), _plain(b)
    if not x or not y:
        return False
    if x in y or y in x or set(x.split()) == set(y.split()):
        return True
    return x.replace(" ", "") == y.replace(" ", "")


def matches(song: Song, wanted: SpotifyImportSong) -> bool:
    """Whether a search result is the song Spotify named: same core title, a shared artist, and a close length."""
    if core_title(song.title) != core_title(wanted.title):
        return False
    if wanted.artists and not any(same_artist(a, t) for a in wanted.artists for t in song.artists):
        return False
    if wanted.duration_ms and song.duration and abs(song.duration - wanted.duration_ms / 1000) > DURATION_SLACK:
        return False
    return True


def query_for(wanted: SpotifyImportSong) -> str:
    return f"{core_title(wanted.title)} {wanted.artists[0] if wanted.artists else ''}".strip()


# ---------- the job ----------

Search = Callable[[str], Awaitable[list[Song]]]


@dataclass
class YouTube:
    """What the import asks YouTube Music for (sources/ytmusic.py; fakes in the tests)."""
    track: Callable[[str], Awaitable[Listing | None]]
    playlist: Callable[[str], Awaitable[tuple[str, list[SpotifyImportSong]] | None]]


_PLAYLIST_ID = re.compile(r"(?:[?&]list=)?([A-Za-z0-9_-]{10,})")


def playlist_id_of(link: str) -> str | None:
    """The id in a playlist link (music.youtube.com/playlist?list=…, youtube.com/watch?v=…&list=…), or a bare id."""
    found = re.search(r"[?&]list=([A-Za-z0-9_-]+)", link) or _PLAYLIST_ID.fullmatch(link.strip())
    return found.group(1) if found else None


async def find(wanted: SpotifyImportSong, search: Search, youtube: YouTube) -> Song | None:
    """The song this entry names. By title, artist and length (matches); a YouTube entry by its video id, with the same
    song's other copies when a search finds it, else on its own."""
    if not wanted.youtube_id:
        return next((s for s in await search(query_for(wanted)) if matches(s, wanted)), None)
    video = None
    if not wanted.title:                                   # a Takeout file may name only the video
        video = await youtube.track(wanted.youtube_id)
        if video is None:
            return None
        wanted = wanted.model_copy(update={"title": video.title, "artists": video.artists, "duration_ms": video.duration * 1000})
    songs = await search(query_for(wanted))
    same = next((s for s in songs if any(l.source == "ytmusic" and l.id == wanted.youtube_id for l in s.listings)), None)
    if same is not None:
        return same
    video = video or await youtube.track(wanted.youtube_id)
    return to_song([video]) if video else None


@dataclass
class ImportJob:
    id: UUID
    user_id: UUID
    groups: list[SpotifyImportGroup]
    total: int
    done: int = 0
    added: int = 0
    missing: list[str] = field(default_factory=list)      # "Title — Artist", for the summary
    finished: bool = False
    failed: str | None = None

    def status(self) -> SpotifyImportStatus:
        return SpotifyImportStatus(id=self.id, total=self.total, done=self.done, added=self.added,
                                   missing=self.missing[:200], finished=self.finished, failed=self.failed)


class ImportHub:
    """Running and finished imports, one running per user (a second would only double the pace at the sources)."""

    def __init__(self) -> None:
        self.jobs: dict[UUID, ImportJob] = {}
        self.tasks: set[asyncio.Task] = set()

    def running_for(self, user_id: UUID) -> ImportJob | None:
        return next((j for j in self.jobs.values() if j.user_id == user_id and not j.finished), None)

    def start(self, pool, search: Search, youtube: YouTube, user_id: UUID, groups: list[SpotifyImportGroup]) -> ImportJob:
        # keep only this user's last few finished jobs: the map would otherwise grow with every import
        for old in [j.id for j in self.jobs.values() if j.user_id == user_id and j.finished][:-4]:
            del self.jobs[old]
        job = ImportJob(id=uuid4(), user_id=user_id, groups=groups, total=sum(len(g.songs) for g in groups))
        self.jobs[job.id] = job
        task = asyncio.create_task(run(job, pool, search, youtube))
        self.tasks.add(task)                                   # kept alive until it ends
        task.add_done_callback(self.tasks.discard)
        return job


async def _new_playlist(conn, user_id: UUID, name: str) -> UUID:
    """A playlist with this name, or "name (2)", "name (3)"… when the user already has one."""
    for n in range(1, 50):
        try:
            async with conn.transaction():
                return await library.create_playlist(conn, user_id, name if n == 1 else f"{name} ({n})")
        except errors.UniqueViolation:
            continue
    raise RuntimeError("no free playlist name")


async def run(job: ImportJob, pool, search: Search, youtube: YouTube) -> None:
    try:
        for group in job.groups:
            songs, name = group.songs, group.name
            if group.youtube_playlist:
                read = None
                if (list_id := playlist_id_of(group.youtube_playlist)) is not None:
                    try:
                        read = await youtube.playlist(list_id)
                    except Exception as e:
                        logger.info("import: a playlist could not be read (%s)", type(e).__name__)
                if read is None:
                    job.missing.append("A YouTube playlist that could not be read (is it private?)")
                    continue
                title, songs = read
                job.total += len(songs)                        # known only now
                if name is None and group.playlist_id is None:
                    name = title
            playlist_id = group.playlist_id
            if playlist_id is None and name is not None:
                async with pool.connection() as conn:
                    playlist_id = await _new_playlist(conn, job.user_id, name)
            for wanted in songs:
                try:
                    found = await find(wanted, search, youtube)
                except Exception as e:                         # a source down for one song is that song not found
                    logger.info("import: a search failed (%s)", type(e).__name__)
                    found = None
                if found is None:
                    job.missing.append(f"{wanted.title} — {', '.join(wanted.artists)}" if wanted.title
                                       else f"YouTube video {wanted.youtube_id}")
                else:
                    async with pool.connection() as conn:
                        song_id = await library.resolve_song(conn, found.listings)
                        if playlist_id is None:
                            await library.like(conn, job.user_id, song_id)
                        else:
                            await library.add_to_playlist(conn, job.user_id, playlist_id, song_id)
                    job.added += 1
                job.done += 1
                await asyncio.sleep(PAUSE_SECONDS)
    except Exception as e:
        logger.warning("import: stopped (%s)", type(e).__name__)
        job.failed = "The import stopped. What was found so far is in your library."
    finally:
        job.finished = True
