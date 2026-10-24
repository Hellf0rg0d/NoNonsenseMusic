-- The releases songs are on, each read once from its source's page (services/releases.py; catalogue identity, 24 Oct).
-- A recording is on many releases: Black Beatles is on JioSaavn's SremmLife 2 and seven compilations ("Best Rap Workout
-- 2023", "Hip Hop Hype", …), Dior by Pop Smoke on five albums. A song's cover is its canonical release's: by the song's
-- own artist, an album before an EP before a single, never a compilation when there is another, then the earliest.
--   kind  'album', 'ep', 'single', or 'compilation' (its artists are "Various Artists"); from the release's own type
--         where the source says (YouTube Music: Album, EP, Single), else from its track count (1 to 3: a single).
CREATE TABLE releases (
    source      text        NOT NULL,
    source_id   text        NOT NULL,
    title       text        NOT NULL,
    artists     text[]      NOT NULL,
    year        integer,
    track_count integer,
    kind        text        NOT NULL CONSTRAINT releases_kind_check CHECK (kind IN ('album', 'ep', 'single', 'compilation')),
    image       text,
    fetched_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, source_id)
);
-- a song's copies' releases, joined by (source, album_id)
CREATE INDEX listings_release_idx ON listings (source, album_id) WHERE album_id IS NOT NULL;
