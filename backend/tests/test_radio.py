"""Exercise POST /radio through the real endpoint: what is asked, what is dropped, what fails.

No network access: each source module's `radio` function is replaced, so a test can give a source
its own reply or its own failure.
"""
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db
from music_backend.models import Listing
from music_backend.sources import SourceBlocked, SourceUnavailable, jiosaavn, ytmusic, youtube
from conftest import TEST_URL, sign_up

pytestmark = pytest.mark.usefixtures("trust_client_listings")



@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    # default: every source answers with no station, so no test can accidentally reach the network
    for module in (jiosaavn, ytmusic, youtube):
        monkeypatch.setattr(module, "radio", empty_radio)
    from music_backend.main import app
    with TestClient(app) as client:
        sign_up(client)
        yield client


async def empty_radio(source_id: str, limit: int = 25) -> list[Listing]:
    return []


def set_radio(monkeypatch, module, listings=None, error=None):
    async def fake(source_id: str, limit: int = 25) -> list[Listing]:
        if error is not None:
            raise error
        return listings or []
    monkeypatch.setattr(module, "radio", fake)


def listing(id, title=None, duration=None):
    """Distinct per id: ranking/group_listings would otherwise merge same-title songs into one."""
    return Listing(source="jiosaavn", id=id, title=title or f"Song {id}", artists=["The Weeknd"],
                   album="After Hours", duration=duration if duration is not None else 200 + len(id),
                   popularity=None)


def radio(seed_source="jiosaavn", seed_id="seed", exclude=None, limit=25):
    body = {"seed": {"source": seed_source, "source_id": seed_id}, "limit": limit}
    if exclude is not None:
        body["exclude"] = exclude
    return body


def test_radio_keeps_the_station_order_and_drops_the_seed(client, monkeypatch):
    set_radio(monkeypatch, jiosaavn, [listing("seed", "Blinding Lights"), listing("s2", "Starboy"),
                                      listing("s3", "Save Your Tears")])
    r = client.post("/radio", json=radio())
    assert r.status_code == 200
    songs = r.json()["songs"]
    assert [s["best"]["id"] for s in songs] == ["s2", "s3"]        # the seed never comes back
    assert [s["title"] for s in songs] == ["Starboy", "Save Your Tears"]   # station order kept
    assert all(s["score"] > 0 for s in songs)                      # RRF ranked, not raw listings


def test_radio_drops_the_app_exclude_list(client, monkeypatch):
    set_radio(monkeypatch, jiosaavn, [listing("seed"), listing("s2"), listing("s3"), listing("s4")])
    r = client.post("/radio", json=radio(exclude=[
        {"source": "jiosaavn", "source_id": "s2"},
        {"source": "ytmusic", "source_id": "whatever"},            # other-source ids are fine to send
    ]))
    assert [s["best"]["id"] for s in r.json()["songs"]] == ["s3", "s4"]


def test_radio_also_drops_your_last_plays_from_the_database(client, monkeypatch):
    set_radio(monkeypatch, jiosaavn, [listing("seed"), listing("played"), listing("fresh")])
    # one play event for "played": it is stored, then the radio must not repeat it
    stored = client.post("/events", json={"type": "play", "position": 0,
                                          "listings": [listing("played").model_dump()]})
    assert stored.status_code == 200
    r = client.post("/radio", json=radio())
    assert [s["best"]["id"] for s in r.json()["songs"]] == ["fresh"]
    # Settings › Playback › Autoplay, "Skip songs played lately" off: it may come back
    r = client.post("/radio", json=radio() | {"skip_recent": False})
    assert [s["best"]["id"] for s in r.json()["songs"]] == ["played", "fresh"]


def store(client, *listings):
    """Store a song with these copies, as a like does (the station uses a stored song's copies)."""
    client.post("/liked", json={"listings": [l.model_dump() for l in listings]})


def test_radio_asks_youtubes_mix_from_the_songs_own_video_first(client, monkeypatch):
    asked = []

    async def mix(source_id, limit=25):
        asked.append(source_id)
        return [listing("from-mix")]

    monkeypatch.setattr(youtube, "radio", mix)
    store(client, listing("jio-own"), Listing(source="ytmusic", id="ytmOwn00001", title="Song jio-own",
                                             artists=["The Weeknd"], album="After Hours", duration=207, popularity=None))
    r = client.post("/radio", json=radio(seed_source="jiosaavn", seed_id="jio-own"))
    assert asked == ["ytmOwn00001"] and [s["best"]["id"] for s in r.json()["songs"]] == ["from-mix"]


def test_radio_finds_a_video_for_a_song_only_jiosaavn_has(client, monkeypatch):
    searched, asked = [], []

    async def search(query):
        searched.append(query)
        return [Listing(source="ytmusic", id="namesake001", title="Song jio-only", artists=["The Weeknd"], album=None,
                        duration=208, popularity=None)]

    async def mix(source_id, limit=25):
        asked.append(source_id)
        return [listing("from-mix")]

    monkeypatch.setattr(ytmusic, "search", search)
    monkeypatch.setattr(youtube, "radio", mix)
    store(client, listing("jio-only"))
    client.post("/radio", json=radio(seed_source="jiosaavn", seed_id="jio-only"))
    assert searched == ["Song jio-only The Weeknd"] and asked == ["namesake001"]


def test_radio_falls_back_when_youtubes_mix_is_empty(client, monkeypatch):
    set_radio(monkeypatch, youtube, [])
    set_radio(monkeypatch, ytmusic, [listing("from-ytm")])
    r = client.post("/radio", json=radio(seed_source="ytmusic", seed_id="J7p4bzqLvCw"))
    assert [s["best"]["id"] for s in r.json()["songs"]] == ["from-ytm"]


def test_radio_asks_only_the_seed_source(client, monkeypatch):
    asked = []

    async def spy(source_id: str, limit: int = 25):
        asked.append(source_id)
        return []

    monkeypatch.setattr(ytmusic, "radio", spy)
    monkeypatch.setattr(youtube, "radio", spy)
    set_radio(monkeypatch, jiosaavn, [listing("x")])
    r = client.post("/radio", json=radio(seed_source="jiosaavn", seed_id="J7p4bzqLvCw"))
    assert r.status_code == 200
    assert asked == []                                              # a JioSaavn id never reaches the others


def test_radio_respects_the_limit(client, monkeypatch):
    # limit=3 counts the songs kept after the seed is dropped: 1 seed + 3 candidates -> 3 back
    set_radio(monkeypatch, jiosaavn, [listing("seed")] + [listing(f"s{i}") for i in range(4)])
    r = client.post("/radio", json=radio(limit=3))
    assert len(r.json()["songs"]) == 3


def test_radio_an_empty_station_is_a_normal_answer(client, monkeypatch):
    r = client.post("/radio", json=radio())                         # default stub returns []
    assert r.status_code == 200 and r.json()["songs"] == []


@pytest.mark.parametrize("error", [SourceUnavailable("down"), SourceBlocked("bot check")])
def test_radio_source_down_is_502(client, monkeypatch, error):
    set_radio(monkeypatch, jiosaavn, error=error)
    r = client.post("/radio", json=radio())
    assert r.status_code == 502
    assert r.json()["detail"] == "jiosaavn is unavailable right now"


def test_radio_needs_a_session(client):
    client.headers.pop("Authorization")
    assert client.post("/radio", json=radio()).status_code == 401


def test_radio_rejects_a_bad_body(client):
    assert client.post("/radio", json={"seed": {"source": "jiosaavn"}}).status_code == 422      # no source_id
    assert client.post("/radio", json=radio(seed_source="deezer")).status_code == 422           # not a source
    assert client.post("/radio", json=radio(limit=0)).status_code == 422                        # below 1
    assert client.post("/radio", json=radio(limit=51)).status_code == 422                       # above 50
    too_many = [{"source": "jiosaavn", "source_id": str(i)} for i in range(101)]
    assert client.post("/radio", json=radio(exclude=too_many)).status_code == 422               # above 100


def test_radio_rate_limit(client, monkeypatch):
    for _ in range(30):
        assert client.post("/radio", json=radio()).status_code == 200
    r = client.post("/radio", json=radio())
    assert r.status_code == 429
    assert "Retry-After" in r.headers


def by(artist, id):
    return Listing(source="youtube", id=id, title=f"Song {id}", artists=[artist], album=None, duration=180, popularity=None)


def test_radio_plays_a_few_songs_by_one_artist_then_another_stations(client, monkeypatch):
    # YouTube's Mix for an upload on a one-artist channel: 22 of 26 by Lee (13 Oct). Three of them, then YouTube
    # Music's station fills the rest
    set_radio(monkeypatch, youtube, [by("Lee", f"lee-{i:02}") for i in range(22)] + [by("Khaim", "khaim")])
    set_radio(monkeypatch, ytmusic, [by(f"Artist {i}", f"ytm-{i:02}") for i in range(10)])
    r = client.post("/radio", json=radio(seed_source="youtube", seed_id="J7p4bzqLvCw", limit=10))
    artists = [s["best"]["artists"][0] for s in r.json()["songs"]]
    assert artists.count("Lee") == 3 and "Khaim" in artists and len(artists) == 10


def test_radio_with_a_varied_mix_asks_no_other_station(client, monkeypatch):
    asked = []

    async def ytmusic_radio(source_id, limit=25):
        asked.append(source_id)
        return []

    set_radio(monkeypatch, youtube, [by(f"Artist {i}", f"mix-{i:02}") for i in range(12)])
    monkeypatch.setattr(ytmusic, "radio", ytmusic_radio)
    r = client.post("/radio", json=radio(seed_source="youtube", seed_id="J7p4bzqLvCw", limit=10))
    assert len(r.json()["songs"]) == 10 and asked == []
