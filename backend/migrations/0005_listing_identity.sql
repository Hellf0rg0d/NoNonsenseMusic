-- What each copy's source says it is, kept instead of dropped (catalogue identity, phase 1; 24 Oct). The server knew
-- names only: a song's cover came from whichever release's copy was picked (Pop Smoke's Dior is on JioSaavn four times,
-- all 216 s), a song and its music video could not be told apart (ZEZE's 4:37 video played, with the song's lyrics),
-- and an artist page was found by name. Every column is nullable: copies stored before this have none until a source
-- returns them again (library.store fills a missing one in), and nothing reads them as required.
--   artist_ids  one per name in `artists`, in order: YouTube Music's channel id ("UC…"), JioSaavn's artist id; NULL in
--               the list where a name has none, or for a video whose artists were read from its title (named()).
--   album_id    the release this copy is on: YouTube Music's album browseId ("MPREb_…"), JioSaavn's album id.
--   kind        'audio' (the song itself: YouTube Music ATV, every JioSaavn song), 'video' (its official video, OMV),
--               'upload' (anyone's: UGC, plain YouTube).
--   year        the release's year, where the source says.
ALTER TABLE listings ADD COLUMN artist_ids text[];
ALTER TABLE listings ADD COLUMN album_id text;
ALTER TABLE listings ADD COLUMN kind text CONSTRAINT listings_kind_check CHECK (kind IN ('audio', 'video', 'upload'));
ALTER TABLE listings ADD COLUMN year integer CONSTRAINT listings_year_check CHECK (year BETWEEN 1900 AND 2100);
