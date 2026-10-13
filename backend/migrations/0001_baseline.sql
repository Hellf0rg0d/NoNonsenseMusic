-- 0001: the schema as it stood when migrations began (13 Oct), every column in its table. Later changes are the
-- numbered files after this one; core/db.py migrate() runs each once, in order, and records it in schema_migrations.
--
--   songs ──< listings      one song, many copies (JioSaavn, YouTube Music)
--     ├────< likes          liked once per person
--     └────< events         play / skip / finish, many per song

CREATE TABLE songs (
    id               uuid        PRIMARY KEY DEFAULT uuidv7(),
    -- identity: copied from the listing that created the song, NEVER updated,
    -- because resolve_song compares new listings against these (a fixed centre stops chaining).
    -- What the app DISPLAYS comes from the best linked listing, computed when read.
    title            text        NOT NULL,
    artists          text[]      NOT NULL,
    duration         integer     NOT NULL CHECK (duration > 0),
    -- normalise() lives in Python, so Postgres cannot index it; store its result instead
    normalised_title text        NOT NULL,
    -- the cover the apps show: chosen once (matching.pick_cover) and never updated, so copies linked later never
    -- change it
    image            text,
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX songs_normalised_title_idx ON songs (normalised_title);


CREATE TABLE listings (
    -- the same id string could exist on two sources, so a listing is identified by BOTH columns
    source     text        NOT NULL CONSTRAINT listings_source_check CHECK (source IN ('jiosaavn', 'ytmusic')),
    source_id  text        NOT NULL,
    -- deleting a song deletes its listings too: a listing means nothing without its song
    song_id    uuid        NOT NULL REFERENCES songs (id) ON DELETE CASCADE,
    title      text        NOT NULL,
    artists    text[]      NOT NULL,
    album      text,
    duration   integer     NOT NULL,
    -- bigint, not integer: YouTube Music reports 3.6 billion plays, and integer stops at ~2.1 billion
    popularity bigint,
    image      text,
    -- explicit version or not (MUS-19): NULL = not known yet, filled in as the listing is seen again
    explicit   boolean,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, source_id)
);

-- "all listings of song S" is a common question; without this it scans the whole table
CREATE INDEX listings_song_id_idx ON listings (song_id);


-- AUTH-1: accounts and sessions. A session is one signed-in device: sign-in makes one, sign-out deletes it, and
-- AUTH-4's device list is these rows. Sessions, not JWTs, so a device can be signed out at once (a JWT stays valid
-- until it expires).
CREATE TABLE users (
    id            uuid        PRIMARY KEY DEFAULT uuidv7(),
    -- 3 to 32 characters (decided 8 Oct; models.py USERNAME_MIN/MAX check it first, with a friendly message)
    username      text        NOT NULL CHECK (length(username) BETWEEN 3 AND 32),
    -- Argon2id's own string: the algorithm, its settings, the salt and the hash in one ("$argon2id$v=19$m=…").
    -- Never the password, in any form
    password_hash text        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- one name regardless of capitals: a plain UNIQUE (username) would let "Alex" and "alex" be two accounts.
-- An index on an expression: the uniqueness is checked on lower(username), and sign-in looks names up the same way
CREATE UNIQUE INDEX users_username_lower_idx ON users (lower(username));

CREATE TABLE sessions (
    -- the SHA-256 of the token (32 bytes), never the token: a leaked table lets no one in. SHA-256 is enough
    -- because the token is 256 random bits, impossible to guess; slow hashing is for passwords, which people choose
    token_hash   bytea       PRIMARY KEY,
    -- a deleted user's sessions go with them (as a deleted song takes its listings)
    user_id      uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_name  text        NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL
);

-- every request finds its session by token_hash (the primary key: indexed already); "my devices" and "sign out
-- everywhere" ask by user, which without this would read the whole table
CREATE INDEX sessions_user_id_idx ON sessions (user_id);
-- the cleanup (auth.delete_expired_sessions, every few hours) reads only the expired rows through this, not the table
CREATE INDEX sessions_expires_at_idx ON sessions (expires_at);

-- Recovery codes (8 Oct): the way back in without the password (there is no email). Ten per account, each used once;
-- shown once (at sign-up, or when a new set is made) and stored only as their SHA-256: a code is 80 random bits, so a
-- fast hash is enough (as for session tokens). Using one is `DELETE … RETURNING`: the check and the using-up are one
-- statement, so two resets with the same code cannot both succeed.
CREATE TABLE recovery_codes (
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    code_hash  bytea       NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, code_hash)
);


CREATE TABLE likes (
    -- whose like (AUTH-3): a deleted user's likes go with them
    user_id  uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    song_id  uuid        NOT NULL REFERENCES songs (id) ON DELETE CASCADE,
    liked_at timestamptz NOT NULL DEFAULT now(),
    -- the key IS the "each person likes a song at most once" rule; led by user_id, it also serves "my likes"
    PRIMARY KEY (user_id, song_id)
);
-- Liked Songs: one user's likes, newest first, read in order from the index (no sort)
CREATE INDEX likes_user_liked_at_idx ON likes (user_id, liked_at DESC);


CREATE TABLE events (
    -- a song is played many times, so events need their own id; the database counts it up for us
    id       bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id  uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    song_id  uuid        NOT NULL REFERENCES songs (id) ON DELETE CASCADE,
    type     text        NOT NULL CHECK (type IN ('play', 'skip', 'finish')),
    -- seconds into the song when it happened: a skip at 12 s means something different from one at 180 s
    position integer     NOT NULL CHECK (position >= 0),
    at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX events_song_id_at_idx ON events (song_id, at);
-- Recently Played: one user's plays, newest first
CREATE INDEX events_user_id_at_idx ON events (user_id, at);


CREATE TABLE playlists (
    id         uuid        PRIMARY KEY DEFAULT uuidv7(),
    -- whose playlist (AUTH-3); its items follow it, so playlist_items needs no user_id of its own
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       text        NOT NULL CHECK (name <> ''),
    -- path of an uploaded cover (MUS-2, cover image part 2); empty means "build a 2x2 grid from the first songs"
    image      text,
    position   text        COLLATE "C" NOT NULL,
    -- a pinned album (MUS-20) is a playlist-shaped row: kind 'album', its source's album id, tracks copied as items
    kind       text        NOT NULL DEFAULT 'playlist',
    source     text,
    source_id  text,
    -- sharing (AUTH-3): public = anyone signed in can view it with its id (a link)
    public     boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- "my playlists, in my order"
CREATE INDEX playlists_user_order_idx ON playlists (user_id, position);

-- your playlist names are unique (an album may share a playlist's name), and one pin per album per person (409)
CREATE UNIQUE INDEX playlists_user_name_key ON playlists (user_id, name) WHERE kind = 'playlist';
CREATE UNIQUE INDEX playlists_album_pin_key ON playlists (user_id, source, source_id) WHERE kind = 'album';

CREATE TABLE playlist_items (
    -- its own id: the same song may appear twice in one playlist
    id          uuid        PRIMARY KEY DEFAULT uuidv7(),
    playlist_id uuid        NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
    song_id     uuid        NOT NULL REFERENCES songs (id) ON DELETE CASCADE,
    -- fractional index (fractional-indexing library); "C" sorts by plain byte value, which the keys need
    position    text        COLLATE "C" NOT NULL,
    -- who added it (a shared playlist shows it); kept when they leave or are deleted: the song stays, unnamed
    added_by    uuid        REFERENCES users (id) ON DELETE SET NULL,
    added_at    timestamptz NOT NULL DEFAULT now()
);

-- "one playlist's items, in order"
CREATE INDEX playlist_items_order_idx ON playlist_items (playlist_id, position);

-- sharing (AUTH-3). The owner is playlists.user_id; everyone else's access is a row here. Roles: viewer (see, play),
-- editor (also add, remove, reorder songs); only the owner renames, deletes, changes public, or invites
CREATE TABLE playlist_members (
    playlist_id uuid        NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role        text        NOT NULL CHECK (role IN ('viewer', 'editor')),
    added_at    timestamptz NOT NULL DEFAULT now(),
    -- one role per person per playlist; led by playlist_id, it also serves "who is in this playlist"
    PRIMARY KEY (playlist_id, user_id)
);
-- "playlists shared with me"
CREATE INDEX playlist_members_user_idx ON playlist_members (user_id);

CREATE TABLE listing_urls (
    source     text        NOT NULL,
    source_id  text        NOT NULL,
    url        text        NOT NULL,
    fetched_at timestamptz NOT NULL DEFAULT now(),   -- when this URL came from the source
    hit_at     timestamptz NOT NULL DEFAULT now(),   -- when it was last used: the trim drops the oldest first
    PRIMARY KEY (source, source_id)
);


-- MUS-12: lyrics replies, one per song as the app asks for it (LyricsCache in cache.py). Timed lyrics are kept
-- for good; plain and empty replies are asked again after LYRICS_RECHECK_DAYS (a source may add them later).
CREATE TABLE lyrics (
    song_name     text        NOT NULL,
    artist_name   text        NOT NULL,
    song_duration integer     NOT NULL,
    youtube_id    text        NOT NULL DEFAULT '',   -- '': asked without a YouTube copy (key columns cannot be NULL)
    reply         jsonb       NOT NULL,              -- the LyricsResponse, exactly as the app gets it
    fetched_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (song_name, artist_name, song_duration, youtube_id)
);


-- Genius notes (experimental, 8 Oct): one reply per song as the app asks for it (GeniusCache in cache.py), for every
-- user. Asked again after GENIUS_RECHECK_DAYS: people keep adding notes. Notes only: Genius's lyrics are never kept.
CREATE TABLE genius (
    song_name   text        NOT NULL,
    artist_name text        NOT NULL,
    reply       jsonb       NOT NULL,                -- the GeniusResponse, exactly as the app gets it
    fetched_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (song_name, artist_name)
);


-- FRIENDS-1: friends and friend requests. A request is one per pair (the PK); a friendship is stored once,
-- the smaller UUID first (the CHECK enforces it), so "are A and B friends?" is one lookup, never two.
CREATE TABLE friend_requests (
    from_user_id uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    to_user_id   uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (from_user_id, to_user_id)
);
CREATE INDEX friend_requests_to_idx ON friend_requests (to_user_id);
-- one pending request per pair, whichever way it was sent
CREATE UNIQUE INDEX friend_requests_pair_idx
    ON friend_requests (least(from_user_id, to_user_id), greatest(from_user_id, to_user_id));

CREATE TABLE friends (
    user_a_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    user_b_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    friends_since timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_a_id, user_b_id),
    CHECK (user_a_id < user_b_id)
);
-- friends_pkey already starts with user_a_id; this serves the other side
CREATE INDEX friends_b_idx ON friends (user_b_id);


-- FRIENDS-1 Phase 2: notifications. seq (BIGSERIAL) is the catch-up cursor — a reconnecting client sends its
-- last_seen_seq and gets everything after it, so a push arriving during the catch-up query is never duplicated.
CREATE TABLE notifications (
    id         uuid        PRIMARY KEY DEFAULT uuidv7(),
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    type       text        NOT NULL,
    payload    jsonb       NOT NULL,
    seq        bigint      GENERATED ALWAYS AS IDENTITY,
    read       boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- the catch-up query: WHERE user_id = X AND seq > cursor ORDER BY seq
CREATE INDEX notifications_user_seq_idx ON notifications (user_id, seq);
-- the unread badge count: WHERE user_id = X AND read = false
CREATE INDEX notifications_user_read_idx ON notifications (user_id, read) WHERE read = false;
-- dedup: one unread friend_request per (user, sender); a second POST /friends/request cannot double-notify
CREATE UNIQUE INDEX notifications_dedup_idx
    ON notifications (user_id, type, (payload->>'from_user_id'))
    WHERE type = 'friend_request' AND read = false;
-- the same for playlist invites: one unread playlist_invite per (user, playlist); share→unshare→share
-- while the first invite is still unread cannot pile up identical notifications
CREATE UNIQUE INDEX notifications_playlist_dedup_idx
    ON notifications (user_id, type, (payload->>'playlist_id'))
    WHERE type = 'playlist_invite' AND read = false;
CREATE UNIQUE INDEX notifications_jam_dedup_idx
    ON notifications (user_id, type, (payload->>'room_id'))
    WHERE type = 'jam_invite' AND read = false;
