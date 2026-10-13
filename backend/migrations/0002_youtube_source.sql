-- Plain YouTube became a search source after listings was made, but its songs could not be stored: liking or adding
-- a YouTube result failed this check (500, 13 Oct).
ALTER TABLE listings DROP CONSTRAINT listings_source_check;
ALTER TABLE listings ADD CONSTRAINT listings_source_check CHECK (source IN ('jiosaavn', 'ytmusic', 'youtube'));
