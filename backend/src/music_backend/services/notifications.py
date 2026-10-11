"""Persist notifications and push them over a WebSocket when the user is connected.

The module has two halves:

* The database half (create / list_notifications / mark_read) is plain functions on a
  connection, like friends.py. Any service can call create() inside its own transaction,
  so the notification commits with the action or neither does.

* The push half (NotificationHub) holds the open WebSocket connections. It does not touch
  the database: after a row is committed the caller (main.py) asks the hub to fan the
  message out. Connections are tracked per user and per socket, so one person on a phone
  and a desktop receives both.

A failure in push never undoes a committed row: a dropped socket is removed from the
registry, not reported as an error.
"""
import asyncio
import json
import logging
import secrets
import time
from typing import Any, Literal
from uuid import UUID

from fastapi import WebSocket
from psycopg import AsyncConnection

from music_backend.models import (NOTIFICATION_PAYLOAD_MODELS, Notification,
                                  NotificationsResponse)

logger = logging.getLogger(__name__)
SEND_TIMEOUT = 3.0
MAX_CONNECTIONS_PER_USER = 5


# ---------- payload validation ----------

def validate_payload(notification_type: str, payload: dict[str, Any]) -> dict[str, Any]:
    """Check the payload against its Pydantic model before it reaches the database.

    An unknown type or a malformed payload raises ValueError: it means a caller has a
    bug, not that the client sent something wrong, so it maps to a 500 in production.
    """
    model = NOTIFICATION_PAYLOAD_MODELS.get(notification_type)
    if model is None:
        raise ValueError(f"unknown notification type {notification_type!r}")
    validated = model(**payload)
    # round-trip through model_dump so UUIDs become str (jsonb needs plain JSON types)
    return json.loads(json.dumps(validated.model_dump(mode="json"), default=str))


# ---------- DB half ----------

async def create(
    conn: AsyncConnection,
    user_id: UUID,
    notification_type: str,
    payload: dict[str, Any],
) -> Notification | None:
    """Insert one notification and return it.

    Returns None when a dedup index rejects the insert. The action itself succeeded, there is nothing new
    new to push. Call inside the caller's transaction so the notification and the
    action commit together.
    """
    clean = validate_payload(notification_type, payload)
    # Identity values are allocated before commit. Serialising inserts for one recipient means
    # a client can never observe seq 12 committed and later receive seq 11 from a slower
    # transaction, which would make its `after_seq=12` reconnect cursor skip 11 forever.
    await conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", [str(user_id)])
    row = await (await conn.execute(
        """INSERT INTO notifications (user_id, type, payload)
           VALUES (%s, %s, %s)
           ON CONFLICT DO NOTHING
           RETURNING id, user_id, type, payload, seq, read, created_at""",
        [user_id, notification_type, json.dumps(clean)],
    )).fetchone()
    if row is None:
        return None
    return _row_to_notification(row)


async def list_notifications(
    conn: AsyncConnection,
    user_id: UUID,
    *,
    unread_only: bool = False,
    after_seq: int = 0,
    before_seq: int | None = None,
    limit: int = 50,
) -> NotificationsResponse:
    """Return a page of one user's notifications plus the current unread count.

    after_seq is the catch-up cursor: everything the client has not seen, used on
    WebSocket reconnect. before_seq is backward pagination: older than this, used when
    scrolling an infinite list. A client normally uses one or the other, not both.
    """
    clauses = ["user_id = %s"]
    params: list[Any] = [user_id]
    if unread_only:
        clauses.append("read = false")
    if after_seq > 0:
        clauses.append("seq > %s")
        params.append(after_seq)
    if before_seq is not None:
        clauses.append("seq < %s")
        params.append(before_seq)
    params.append(limit)
    rows = await (await conn.execute(
        f"""SELECT id, user_id, type, payload, seq, read, created_at
              FROM notifications
             WHERE {' AND '.join(clauses)}
             ORDER BY seq DESC
             LIMIT %s""",
        params,
    )).fetchall()
    unread = await unread_count(conn, user_id)
    return NotificationsResponse(
        notifications=[_row_to_notification(r) for r in rows],
        unread_count=unread,
    )


async def mark_read(conn: AsyncConnection, user_id: UUID,
                    notification_id: UUID) -> Literal["read", "already_read", "not_found"]:
    """Mark one notification read and report the outcome.

    Returns "not_found" only when the notification does not exist or belongs to another
    user. Re-marking an already-read notification returns "already_read": the call is
    idempotent, not an error.
    """
    changed = (await conn.execute(
        "UPDATE notifications SET read = true WHERE id = %s AND user_id = %s AND read = false",
        [notification_id, user_id],
    )).rowcount
    if changed:
        return "read"
    exists = await (await conn.execute(
        "SELECT 1 FROM notifications WHERE id = %s AND user_id = %s",
        [notification_id, user_id],
    )).fetchone()
    return "already_read" if exists else "not_found"


async def mark_all_read(conn: AsyncConnection, user_id: UUID) -> int:
    """Mark every unread notification read. Return how many changed."""
    return (await conn.execute(
        "UPDATE notifications SET read = true WHERE user_id = %s AND read = false",
        [user_id],
    )).rowcount


async def unread_count(conn: AsyncConnection, user_id: UUID) -> int:
    row = await (await conn.execute(
        "SELECT count(*) AS n FROM notifications WHERE user_id = %s AND read = false",
        [user_id],
    )).fetchone()
    return row["n"]


async def delete_old(conn: AsyncConnection, days: int = 30) -> int:
    """Remove notifications older than `days`."""
    return (await conn.execute(
        "DELETE FROM notifications WHERE created_at < now() - make_interval(days => %s)",
        [days],
    )).rowcount


async def clean_forever(pool, days: int = 30, every_seconds: int = 6 * 3600) -> None:
    """Run the periodic cleanup task (started from main.lifespan, alongside sessions).

    Every `every_seconds`, drop notifications older than `days`. Sleeps first so startup
    work is not delayed.
    """
    while True:
        await asyncio.sleep(every_seconds)
        try:
            async with pool.connection() as conn:
                await delete_old(conn, days)
        except Exception as e:
            # as in auth.clean_sessions_forever: one failed round must not end the loop, and only the class is logged
            logger.warning("notification cleanup failed: %s", type(e).__name__)


def _row_to_notification(row) -> Notification:
    return Notification(
        id=row["id"],
        user_id=row["user_id"],
        type=row["type"],
        payload=row["payload"],
        seq=row["seq"],
        read=row["read"],
        created_at=row["created_at"],
    )


# ---------- push half: the connection registry ----------

class NotificationHub:
    """Registry of open WebSocket connections, keyed by user. One user can hold many sockets.

    Lives on app.state. Only touched from the event loop (async def endpoints), so no lock
    is needed: there is no await between check and mutate in push().
    """

    def __init__(self) -> None:
        self._connections: dict[UUID, set[WebSocket]] = {}
        # single-use WS tickets: ticket string -> (user_id, expires_at monotonic)
        self._tickets: dict[str, tuple[UUID, float]] = {}

    # --- connections ---

    def register(self, user_id: UUID, ws: WebSocket) -> bool:
        """Register a socket, returning False when this user already has the safe cap."""
        conns = self._connections.setdefault(user_id, set())
        if len(conns) >= MAX_CONNECTIONS_PER_USER:
            return False
        conns.add(ws)
        return True

    def unregister(self, user_id: UUID, ws: WebSocket) -> None:
        conns = self._connections.get(user_id)
        if conns is not None:
            conns.discard(ws)
            if not conns:
                del self._connections[user_id]

    def connection_count(self, user_id: UUID) -> int:
        return len(self._connections.get(user_id, ()))

    async def push(self, user_id: UUID, message: dict[str, Any]) -> int:
        """Send one JSON message to every socket this user has open. Return how many got it.

        A socket that raises (closed, network gone) is removed; the others still receive.

        Two races, both real, follow from send_json awaiting: anything on the event loop
        may run during that await. (1) Iterate a copy of the set: a disconnecting socket's
        task calls unregister() and mutates the original mid-loop, which would raise "set
        changed size during iteration". (2) Remove the user only if the dict still holds
        this same set: a socket that dies and reconnects during the await has already
        replaced it with a fresh set, and popping that would leave the new connection
        dark (registered in a set nobody has a reference to).
        """
        conns = self._connections.get(user_id)
        if not conns:
            return 0
        sockets = list(conns)

        async def send(ws: WebSocket) -> bool:
            try:
                await asyncio.wait_for(ws.send_json(message), timeout=SEND_TIMEOUT)
                return True
            except Exception:
                return False

        results = await asyncio.gather(*(send(ws) for ws in sockets))
        dead = [ws for ws, delivered in zip(sockets, results) if not delivered]
        for ws in dead:
            conns.discard(ws)
        if not conns and self._connections.get(user_id) is conns:
            del self._connections[user_id]
        return len(sockets) - len(dead)

    async def close_user(self, user_id: UUID, *, code: int = 4401, reason: str = "signed out") -> None:
        """End a user's live notification channels and invalidate unopened WS tickets."""
        self._tickets = {ticket: value for ticket, value in self._tickets.items() if value[0] != user_id}
        sockets = list(self._connections.pop(user_id, set()))
        await asyncio.gather(*(self._close(ws, code, reason) for ws in sockets), return_exceptions=True)

    @staticmethod
    async def _close(ws: WebSocket, code: int, reason: str) -> None:
        try:
            await asyncio.wait_for(ws.close(code=code, reason=reason), timeout=SEND_TIMEOUT)
        except Exception:
            pass

    # --- tickets: the JWT never appears in a URL ---

    def issue_ticket(self, user_id: UUID, ttl_seconds: int = 30) -> str:
        """Mint a single-use ticket for the WebSocket handshake. The client trades its JWT for this."""
        self._prune_tickets()
        ticket = secrets.token_urlsafe(32)
        self._tickets[ticket] = (user_id, time.monotonic() + ttl_seconds)
        return ticket

    def redeem_ticket(self, ticket: str) -> UUID | None:
        """Consume a ticket: return the user id once, then the ticket is gone (single-use)."""
        entry = self._tickets.pop(ticket, None)
        if entry is None:
            return None
        user_id, expires_at = entry
        if time.monotonic() > expires_at:
            return None
        return user_id

    def _prune_tickets(self) -> None:
        now = time.monotonic()
        expired = [t for t, (_, exp) in self._tickets.items() if now > exp]
        for t in expired:
            del self._tickets[t]
