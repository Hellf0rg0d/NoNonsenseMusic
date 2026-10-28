-- JioSaavn has songs only (sources/jiosaavn.py stores every listing as kind 'audio'), so its copies stored before kinds
-- were kept (0005) are songs too. Unmarked, they ranked below another source's 'audio' copy in pick_best, whose first
-- rule is the kind: one song on the server played YouTube Music's 128 kbps copy over JioSaavn's 320 kbps one (28 Oct;
-- 148 such listings).
UPDATE listings SET kind = 'audio' WHERE source = 'jiosaavn' AND kind IS NULL;
