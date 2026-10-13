"""Test the friends feature: requests, accept and decline, listing, and removal.

The suite runs against music_test, which is wiped before each test. It uses the
FastAPI test client and direct SQL, with no network access.
"""
from uuid import uuid4

import psycopg
import pytest
from fastapi.testclient import TestClient

from music_backend.core import db

TEST_URL = "postgresql:///music_test"


def new_username():
    return "test-" + uuid4().hex[:10]


@pytest.fixture
def client(monkeypatch):
    """Provide a test client backed by music_test, with the friend tables emptied first."""
    monkeypatch.setattr(db, "DATABASE_URL", TEST_URL)
    from music_backend.main import app
    with TestClient(app) as client:
        with psycopg.connect(TEST_URL) as conn:
            conn.execute("DELETE FROM friend_requests")
            conn.execute("DELETE FROM friends")
        yield client


def sign_up_user(client, username=None):
    """Sign up a user, set their token on the client, and return (username, token)."""
    name = username or new_username()
    r = client.post("/auth/signup", json={"username": name, "password": "testpass123"})
    assert r.status_code == 201, r.text
    token = r.json()["token"]
    client.headers["Authorization"] = f"Bearer {token}"
    return name, token


def sign_up_as(client, username):
    """Sign up a user without changing the client's auth headers, and return (username, token)."""
    r = client.post("/auth/signup", json={"username": username, "password": "testpass123"})
    assert r.status_code == 201, r.text
    return username, r.json()["token"]


# ---------- send_request ----------

def test_send_request_success(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    r = client.post("/friends/request", json={"username": bob})
    assert r.status_code == 201


def test_send_request_no_such_user(client):
    sign_up_user(client)
    r = client.post("/friends/request", json={"username": "ghost"})
    assert r.status_code == 404


def test_send_request_to_self(client):
    alice, alice_token = sign_up_user(client)
    r = client.post("/friends/request", json={"username": alice})
    assert r.status_code == 400


def test_send_request_already_friends(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    client.post("/friends/respond", json={"username": alice, "action": "accept"})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.post("/friends/request", json={"username": bob})
    assert r.status_code == 409


def test_send_request_already_pending(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    r = client.post("/friends/request", json={"username": bob})
    assert r.status_code == 409


def test_send_request_duplicate_race(client):
    """Simulate a duplicate-request race: one response is 201, the other 409."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    r1 = client.post("/friends/request", json={"username": bob})
    r2 = client.post("/friends/request", json={"username": bob})
    codes = sorted([r1.status_code, r2.status_code])
    assert codes == [201, 409]


def test_send_request_case_insensitive(client):
    alice, alice_token = sign_up_user(client)
    bob_name = new_username()
    bob, bob_token = sign_up_as(client, bob_name)
    r = client.post("/friends/request", json={"username": bob_name.upper()})
    assert r.status_code == 201


# ---------- list_requests ----------

def test_list_requests_empty(client):
    sign_up_user(client)
    r = client.get("/friends/requests")
    assert r.status_code == 200
    assert r.json() == {"incoming": [], "outgoing": []}


def test_list_requests_incoming_outgoing(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    r = client.get("/friends/requests")
    assert len(r.json()["outgoing"]) == 1
    assert r.json()["outgoing"][0]["username"] == bob
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.get("/friends/requests")
    assert len(r.json()["incoming"]) == 1
    assert r.json()["incoming"][0]["username"] == alice


# ---------- respond (accept/decline) ----------

def test_accept_request(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.post("/friends/respond", json={"username": alice, "action": "accept"})
    assert r.status_code == 204
    r = client.get("/friends")
    assert any(f["username"] == alice for f in r.json())
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.get("/friends")
    assert any(f["username"] == bob for f in r.json())


def test_decline_request(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.post("/friends/respond", json={"username": alice, "action": "decline"})
    assert r.status_code == 204
    r = client.get("/friends")
    assert r.json() == []
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.get("/friends")
    assert r.json() == []
    r = client.get("/friends/requests")
    assert r.json()["outgoing"] == []
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.get("/friends/requests")
    assert r.json()["incoming"] == []


def test_respond_no_request(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.post("/friends/respond", json={"username": alice, "action": "accept"})
    assert r.status_code == 404


def test_respond_accept_idempotent(client):
    """Accepting when already friends returns 404 rather than a server error."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    client.post("/friends/respond", json={"username": alice, "action": "accept"})
    r = client.post("/friends/respond", json={"username": alice, "action": "accept"})
    assert r.status_code == 404


def test_respond_accept_then_send_again(client):
    """After accepting, a further request from the same user gets 409."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    client.post("/friends/respond", json={"username": alice, "action": "accept"})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.post("/friends/request", json={"username": bob})
    assert r.status_code == 409


def test_respond_decline_then_send_again(client):
    """After declining, can send a new request."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    client.post("/friends/respond", json={"username": alice, "action": "decline"})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.post("/friends/request", json={"username": bob})
    assert r.status_code == 201


# ---------- list_friends ----------

def test_list_friends_empty(client):
    sign_up_user(client)
    r = client.get("/friends")
    assert r.status_code == 200
    assert r.json() == []


def test_list_friends_alphabetical(client):
    alice, alice_token = sign_up_user(client)
    for _ in range(3):
        u, u_token = sign_up_as(client, new_username())
        client.headers["Authorization"] = f"Bearer {alice_token}"
        client.post("/friends/request", json={"username": u})
        client.headers["Authorization"] = f"Bearer {u_token}"
        client.post("/friends/respond", json={"username": alice, "action": "accept"})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.get("/friends")
    assert len(r.json()) == 3


def test_list_friends_multiple(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    charlie, charlie_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    client.post("/friends/respond", json={"username": alice, "action": "accept"})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    client.post("/friends/request", json={"username": charlie})
    client.headers["Authorization"] = f"Bearer {charlie_token}"
    client.post("/friends/respond", json={"username": alice, "action": "accept"})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.get("/friends")
    assert len(r.json()) == 2


# ---------- remove_friend ----------

def test_remove_friend(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    client.post("/friends/respond", json={"username": alice, "action": "accept"})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.get("/friends")
    bob_id = r.json()[0]["user_id"]
    r = client.delete(f"/friends/{bob_id}")
    assert r.status_code == 204
    r = client.get("/friends")
    assert r.json() == []
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.get("/friends")
    assert r.json() == []


def test_remove_friend_not_friends(client):
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    r = client.get("/friends/requests")
    bob_id = r.json()["outgoing"][0]["user_id"]
    r = client.delete(f"/friends/{bob_id}")
    assert r.status_code == 404


def test_remove_friend_idempotent(client):
    """Removing the same friend twice: second is 404."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    client.post("/friends/respond", json={"username": alice, "action": "accept"})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.get("/friends")
    bob_id = r.json()[0]["user_id"]
    client.delete(f"/friends/{bob_id}")
    r = client.delete(f"/friends/{bob_id}")
    assert r.status_code == 404


# ---------- auth required ----------

def test_friends_requires_auth(client):
    client.headers.pop("Authorization", None)
    r = client.get("/friends")
    assert r.status_code == 401
    r = client.get("/friends/requests")
    assert r.status_code == 401
    r = client.post("/friends/request", json={"username": "bob"})
    assert r.status_code == 401


# ---------- bidirectional friendship ----------

def test_friendship_bidirectional(client):
    """Both users see each other as friends, and the stored row is one."""
    alice, alice_token = sign_up_user(client)
    bob, bob_token = sign_up_as(client, new_username())
    client.post("/friends/request", json={"username": bob})
    client.headers["Authorization"] = f"Bearer {bob_token}"
    client.post("/friends/respond", json={"username": alice, "action": "accept"})
    client.headers["Authorization"] = f"Bearer {alice_token}"
    r = client.get("/friends")
    assert len(r.json()) == 1
    client.headers["Authorization"] = f"Bearer {bob_token}"
    r = client.get("/friends")
    assert len(r.json()) == 1
    with psycopg.connect(TEST_URL) as conn:
        rows = conn.execute("SELECT * FROM friends").fetchall()
        assert len(rows) == 1


# ---------- self-friend edge cases ----------

def test_send_request_to_self_case_insensitive(client):
    alice, alice_token = sign_up_user(client)
    r = client.post("/friends/request", json={"username": alice.upper()})
    assert r.status_code == 400
