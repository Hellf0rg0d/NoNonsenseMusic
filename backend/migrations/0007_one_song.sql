-- One recording, one song (24 Oct). ZEZE was two songs: "(feat. Travis Scott & Offset)" on JioSaavn, "(feat. Offset &
-- Travis Scott)" on YouTube Music, and songs were found by their whole title only.
--
-- core_title: a song's title without who it features (matching.core_title), which resolve_song finds songs by. Python
-- writes it, as normalised_title; the songs stored before get theirs at start (library.fill_core_titles).
ALTER TABLE songs ADD COLUMN core_title text;
CREATE INDEX songs_core_title_idx ON songs (core_title);

-- A song merged into the song it was a copy of (library.merge_songs): the song as it was and what moved from it, so a
-- wrong merge can be split again (library.split_song), and its id still leads to where its copies went.
CREATE TABLE song_merges (
    from_id   uuid        PRIMARY KEY,
    into_id   uuid        NOT NULL REFERENCES songs (id) ON DELETE CASCADE,
    why       text        NOT NULL,
    song      jsonb       NOT NULL,     -- its songs row
    moved     jsonb       NOT NULL,     -- {listings: [[source, id]], likes: [{user, at, kept}], events: [id], items: [id]}
    merged_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX song_merges_into_idx ON song_merges (into_id);
