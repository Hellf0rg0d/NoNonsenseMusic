// Which copy of a song plays, and that its cover does not depend on the copy. All fixture data is made up.
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/models.dart';

Listing copy(String source, String id, {bool? explicit, int popularity = 0, String? image, String? kind}) => Listing(
    source: source, id: id, title: 'Song', artists: const ['Kai'], duration: 200, popularity: popularity, explicit: explicit, image: image,
    kind: kind);

void main() {
  tearDown(() {
    Track.preferredSource = null;
    Track.prefersExplicit = true;
  });

  group('preferred source', () {
    final saavn = copy('jiosaavn', 's1', explicit: false, popularity: 90);
    final music = copy('ytmusic', 'm1', explicit: false, popularity: 50);
    final video = copy('youtube', 'v1', popularity: 10);

    test('Automatic keeps the server\'s pick', () {
      expect(Track(saavn, [music, video]).best, saavn);
      expect(Track(music, [saavn, video]).best, music);
    });

    test('a chosen source\'s copy plays when the song has one, whatever the server picked', () {
      Track.preferredSource = 'ytmusic';
      expect(Track(saavn, [saavn, music, video]).best, music);
      Track.preferredSource = 'youtube';
      expect(Track(saavn, [saavn, music, video]).best, video, reason: 'a copy whose version is not known still counts');
    });

    test('a source the song does not have changes nothing', () {
      Track.preferredSource = 'youtube';
      expect(Track(saavn, [music]).best, saavn);
    });

    test('the version still wins over the source: the clean copy is chosen when the preferred source has only explicit', () {
      final loud = copy('ytmusic', 'm2', explicit: true);
      final clean = copy('jiosaavn', 's2', explicit: false);
      Track.preferredSource = 'ytmusic';
      Track.prefersExplicit = false;
      expect(Track(loud, [loud, clean]).best, clean);
      Track.prefersExplicit = true;
      expect(Track(clean, [loud, clean]).best, loud);
    });

    test('a copy chosen by hand plays exactly as given', () {
      Track.preferredSource = 'ytmusic';
      final t = Track(saavn, [saavn, music]).playing(saavn);
      expect(t.best, saavn);
      expect(t.listings.first, saavn, reason: 'the fallback order starts at the chosen copy');
    });
  });

  group('cover', () {
    final a = copy('jiosaavn', 'a', image: 'https://img.test/a.jpg', popularity: 99);
    final b = copy('ytmusic', 'b', image: 'https://img.test/b.jpg');

    test('the server\'s song cover is kept when another copy plays', () {
      final song = Track(a, [a, b], image: 'https://img.test/song.jpg');
      expect(song.image, 'https://img.test/song.jpg');
      expect(song.playing(b).image, 'https://img.test/song.jpg');
      Track.preferredSource = 'ytmusic';
      expect(Track(a, [a, b], image: 'https://img.test/song.jpg').image, 'https://img.test/song.jpg');
    });

    test('without one, the cover depends on the set of copies and not on their order or which plays', () {
      final covers = {
        Track(a, [a, b]).image,
        Track(b, [b, a]).image,
        Track(a, [a, b]).playing(b).image,
        Track(b, [a, b]).playing(a).image,
      };
      expect(covers, {'https://img.test/b.jpg'}, reason: 'YouTube Music\'s picture comes first');
    });

    test('a song with no picture anywhere has none', () {
      expect(Track(copy('jiosaavn', 'x'), const []).image, isNull);
    });

    test('a song from the server carries its cover', () {
      final t = Track.fromSong({
        'best': a.toJson(),
        'listings': [a.toJson(), b.toJson()],
        'image': 'https://img.test/song.jpg',
      });
      expect(t.image, 'https://img.test/song.jpg');
    });
  });

  group('the song before its video', () {
    // ZEZE: the 4:37 music video had more views than the 3:49 song had plays, played, and the song's lyrics ran early
    final song = copy('ytmusic', 'atv', explicit: true, popularity: 50, kind: 'audio');
    final video = copy('ytmusic', 'omv', explicit: true, popularity: 900, kind: 'video');

    test('a chosen source plays its song, not its more viewed video', () {
      Track.preferredSource = 'ytmusic';
      expect(Track(copy('jiosaavn', 's', explicit: true), [video, song]).best, song);
    });

    test('a failed song falls back to another song before a video', () {
      final other = copy('ytmusic', 'atv2', popularity: 1, kind: 'audio');
      expect(Track(song, [video, other]).listings.map((l) => l.id), ['atv', 'atv2', 'omv']);
    });

    test('the kind is kept when saved and read back', () {
      expect(Listing.fromJson(video.toJson()).kind, 'video');
    });
  });

  test('every source is named', () {
    expect([for (final s in ['jiosaavn', 'ytmusic', 'youtube']) copy(s, 'x').sourceName], ['JioSaavn', 'YouTube Music', 'YouTube']);
    expect(copy('jiosaavn', 'x').quality, 'AAC 320 kbps');
    expect(copy('youtube', 'x').quality, 'AAC 128 kbps');
  });
}
