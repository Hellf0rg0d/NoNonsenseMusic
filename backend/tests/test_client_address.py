"""Which address a request counts as: the connecting peer, or what a trusted proxy says in X-Forwarded-For."""
import pytest
from fastapi import HTTPException
from pydantic import ValidationError
from starlette.requests import Request

from music_backend.core.ratelimit import Limiter, client_address, is_local
from music_backend.core.settings import Settings, settings


def request(peer, forwarded=None, **headers):
    """Build a request that arrived from `peer`, carrying X-Forwarded-For when given."""
    if forwarded is not None:
        headers["x-forwarded-for"] = forwarded
    raw = [(name.encode(), value.encode()) for name, value in headers.items()]
    return Request({"type": "http", "client": (peer, 50000), "headers": raw})


def hits_until_refused(limiter, requests):
    """Count the requests the signup limit lets through before it answers 429."""
    for count, r in enumerate(requests):
        try:
            limiter.check_address(r, "signup_address")
        except HTTPException as e:
            assert e.status_code == 429
            return count
    return len(requests)


def test_a_header_from_a_peer_that_is_not_trusted_is_ignored(monkeypatch):
    monkeypatch.setattr(settings, "trusted_proxies", "10.0.0.0/8")
    assert client_address(request("198.51.100.4", "10.0.0.1, 203.0.113.9")) == ("198.51.100.4", False)
    # and a made-up address per request does not make a new limit
    limiter = Limiter()
    spoofed = (request("198.51.100.4", f"203.0.113.{n}") for n in range(20))
    assert hits_until_refused(limiter, spoofed) == 5


def test_a_trusted_proxy_chain_gives_the_rightmost_address_that_is_not_a_proxy(monkeypatch):
    monkeypatch.setattr(settings, "trusted_proxies", "10.0.0.0/8, 192.0.2.1")
    # 6.6.6.6 is what the caller wrote; 203.0.113.9 was added by the edge proxy 192.0.2.1; 10.0.0.7 is the peer's neighbour
    chain = "6.6.6.6, 203.0.113.9, 192.0.2.1, 10.0.0.7"
    assert client_address(request("10.0.0.5", chain)) == ("203.0.113.9", True)
    assert client_address(request("10.0.0.5")) == ("10.0.0.5", True)           # no header: the proxy itself


def test_nothing_behind_a_proxy_counts_as_local(monkeypatch):
    assert is_local(request("127.0.0.1")) and is_local(request("::1"))
    assert not is_local(request("127.0.0.1", "203.0.113.9"))      # a proxy on this machine that is not listed
    monkeypatch.setattr(settings, "trusted_proxies", "127.0.0.1")
    assert not is_local(request("127.0.0.1", "127.0.0.1"))        # a caller who writes "127.0.0.1" is not local
    assert not is_local(request("127.0.0.1"))                     # nor is the proxy's own check


def test_an_ipv6_caller_is_one_address_per_64():
    inside = [request(f"2001:db8:1:2:{n:x}::9") for n in range(1, 20)]
    assert hits_until_refused(Limiter(), inside) == 5
    other_64 = [request(f"2001:db8:1:3::{n:x}") for n in range(1, 4)]
    assert hits_until_refused(Limiter(), other_64) == 3


def test_a_bad_trusted_proxy_stops_the_server_at_startup():
    with pytest.raises(ValidationError):
        Settings(_env_file=None, trusted_proxies="10.0.0.0/8, not-an-address")
