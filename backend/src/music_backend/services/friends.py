"""Send friend requests, accept or decline them, list friends, and remove them.

Same pattern as library.py: main.py opens the connection, this file runs the SQL.
Custom exceptions map to HTTP status codes in main.py.

send_request and respond create a notification row inside their own transaction (the action
and its notification commit or roll back together) and return it so main.py can push it over
the WebSocket after the commit. Returning None means there is nothing to push (dedup
suppressed it).
"""
from uuid import UUID

from psycopg import AsyncConnection, errors

from music_backend.models import FriendUser, Notification
from music_backend.services import notifications


class NoSuchUser(Exception):
    """No account with that username (the endpoint's 404)."""


class AlreadyFriends(Exception):
    """The two users are already friends (the endpoint's 409)."""


class RequestPending(Exception):
    """A request between the two users is already pending (the endpoint's 409)."""


class NoRequest(Exception):
    """No pending request from this person (the endpoint's 404)."""


class NotFriends(Exception):
    """The two users are not friends (the endpoint's 404)."""


async def _find_user(conn: AsyncConnection, username: str) -> UUID:
    """Return the user id behind a username, or raise NoSuchUser.

    The lookup is case-insensitive, matching sign-in.
    """
    row = await (await conn.execute(
        "SELECT id FROM users WHERE lower(username) = lower(%s)", [username])).fetchone()
    if row is None:
        raise NoSuchUser(username)
    return row["id"]





async def are_friends(conn: AsyncConnection, a: UUID, b: UUID) -> bool:
    """Return whether the two users are friends (one lookup: the pair is stored once, the smaller id first)."""
    lo, hi = (a, b) if a < b else (b, a)
    return await (await conn.execute(
        "SELECT 1 FROM friends WHERE user_a_id = %s AND user_b_id = %s", [lo, hi])).fetchone() is not None


async def send_request(conn: AsyncConnection, from_user: UUID, to_username: str) -> Notification | None:
    """Send a friend request and return the notification for the WebSocket push.

    Raises NoSuchUser, AlreadyFriends (409), RequestPending (409) or ValueError (400) when the
    recipient is the sender.

    The recipient's friend_request notification is created in the same transaction. It is
    returned for the push, or None if dedup suppressed it (an unread request from the same
    sender already exists).
    """
    to_id = await _find_user(conn, to_username)
    if to_id == from_user:
        raise ValueError("cannot send a friend request to yourself")
    lo, hi = (from_user, to_id) if from_user < to_id else (to_id, from_user)
    async with conn.transaction():
        row = await (await conn.execute(
            """SELECT EXISTS(SELECT 1 FROM friends WHERE user_a_id = %s AND user_b_id = %s) AS are_friends,
                      EXISTS(SELECT 1 FROM friend_requests
                               WHERE (from_user_id = %s AND to_user_id = %s)
                                  OR (from_user_id = %s AND to_user_id = %s)) AS request_pending""",
            [lo, hi, from_user, to_id, to_id, from_user])).fetchone()
        if row["are_friends"]:
            raise AlreadyFriends()
        if row["request_pending"]:
            raise RequestPending()
        inserted = await (await conn.execute(
            """INSERT INTO friend_requests (from_user_id, to_user_id) VALUES (%s, %s)
                 ON CONFLICT DO NOTHING RETURNING from_user_id""",
            [from_user, to_id])).fetchone()
        if inserted is None:
            # ON CONFLICT handles both a duplicate click and an opposite-direction request.
            # It avoids catching UniqueViolation inside this transaction, which otherwise
            # leaves the connection aborted until the surrounding block exits.
            raise RequestPending()
        sender = await (await conn.execute(
            "SELECT username FROM users WHERE id = %s", [from_user])).fetchone()
        return await notifications.create(conn, to_id, "friend_request", {
            "from_user_id": str(from_user),
            "from_username": sender["username"],
        })


async def list_requests(conn: AsyncConnection, user_id: UUID) -> tuple[list[FriendUser], list[FriendUser]]:
    """Return the (incoming, outgoing) pending requests for this user, each oldest first."""
    incoming_rows = await (await conn.execute(
        """SELECT u.id AS user_id, u.username, r.created_at AS since
             FROM friend_requests r JOIN users u ON u.id = r.from_user_id
            WHERE r.to_user_id = %s
            ORDER BY r.created_at""",
        [user_id])).fetchall()
    outgoing_rows = await (await conn.execute(
        """SELECT u.id AS user_id, u.username, r.created_at AS since
             FROM friend_requests r JOIN users u ON u.id = r.to_user_id
            WHERE r.from_user_id = %s
            ORDER BY r.created_at""",
        [user_id])).fetchall()
    incoming = [FriendUser(user_id=r["user_id"], username=r["username"], since=r["since"]) for r in incoming_rows]
    outgoing = [FriendUser(user_id=r["user_id"], username=r["username"], since=r["since"]) for r in outgoing_rows]
    return incoming, outgoing


async def respond(conn: AsyncConnection, user_id: UUID, from_username: str, action: str) -> Notification | None:
    """Accept or decline a pending friend request.

    Raises NoRequest (404) when there is no pending request from that user.

    Accept: delete the request, insert the friendship (idempotent: if the pair is already
    friends only the request is deleted), and create a friend_accepted notification for the
    requester in the same transaction. Decline: delete the request, create no notification.

    Returns the notification for the push, or None when the request was declined or dedup
    suppressed the notification.
    """
    from_id = await _find_user(conn, from_username)
    async with conn.transaction():
        # lock the request row so a simultaneous accept + decline is one or the other, not both
        row = await (await conn.execute(
            "SELECT from_user_id, to_user_id FROM friend_requests WHERE from_user_id = %s AND to_user_id = %s FOR UPDATE",
            [from_id, user_id])).fetchone()
        if row is None:
            raise NoRequest()
        await conn.execute(
            "DELETE FROM friend_requests WHERE from_user_id = %s AND to_user_id = %s",
            [from_id, user_id])
        # the request is gone, so its notification is stale: keep the row as history but clear
        # the badge. Without this, declining or accepting leaves a red "friend request" forever
        # that points at a request that no longer exists.
        await conn.execute(
            """UPDATE notifications SET read = true
                WHERE user_id = %s AND type = 'friend_request'
                  AND payload->>'from_user_id' = %s AND read = false""",
            [user_id, str(from_id)])
        if action == "accept":
            lo, hi = (from_id, user_id) if from_id < user_id else (user_id, from_id)
            try:
                await conn.execute(
                    "INSERT INTO friends (user_a_id, user_b_id) VALUES (%s, %s)",
                    [lo, hi])
            except errors.UniqueViolation:
                pass  # already friends (race): the request is still gone, which is what matters
            accepter = await (await conn.execute(
                "SELECT username FROM users WHERE id = %s", [user_id])).fetchone()
            return await notifications.create(conn, from_id, "friend_accepted", {
                "by_user_id": str(user_id),
                "by_username": accepter["username"],
            })
        return None


async def list_friends(conn: AsyncConnection, user_id: UUID) -> list[FriendUser]:
    """Return all friends of the user, alphabetical by username."""
    rows = await (await conn.execute(
        """WITH mine AS (
                 SELECT user_b_id AS friend_id, friends_since FROM friends WHERE user_a_id = %s
                 UNION ALL
                 SELECT user_a_id AS friend_id, friends_since FROM friends WHERE user_b_id = %s
               )
               SELECT u.id AS user_id, u.username, m.friends_since AS since
                 FROM mine m JOIN users u ON u.id = m.friend_id
                ORDER BY u.username""",
        [user_id, user_id])).fetchall()
    return [FriendUser(user_id=r["user_id"], username=r["username"], since=r["since"]) for r in rows]


async def remove_friend(conn: AsyncConnection, user_id: UUID, friend_id: UUID) -> None:
    """Remove a friend. Raises NotFriends (404) when the users are not friends."""
    lo, hi = (user_id, friend_id) if user_id < friend_id else (friend_id, user_id)
    deleted = (await conn.execute(
        "DELETE FROM friends WHERE user_a_id = %s AND user_b_id = %s",
        [lo, hi])).rowcount
    if deleted == 0:
        raise NotFriends()
