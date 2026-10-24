// A song's artist and album open the pages its copies' sources name (artistOf, albumOf), by id. A name alone opened
// whoever a search put first: Nav's song opened "Nav Tyler" (24 Oct).
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/catalog.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/ui/browse_nav.dart';

Listing copy(String source, String id, {List<String> artists = const ['Pop Smoke'], List<String?>? ids, String? album, String? albumId}) =>
    Listing(source: source, id: id, title: 'Dior', artists: artists, album: album, duration: 216, artistIds: ids, albumId: albumId);

Track track(List<Listing> copies) => Track(copies.first, copies, choosingVersion: false);

void main() {
  test("an artist opens the page its copy's source names", () {
    final t = track([copy('jiosaavn', 'a', artists: ['Pop Smoke', 'Rowdy Rebel'], ids: ['5964868', null])]);
    expect(artistOf(t, 'Pop Smoke'), const ArtistTarget(ArtistRef(source: 'jiosaavn', id: '5964868', name: 'Pop Smoke')));
    expect(artistOf(t, 'Rowdy Rebel'), const ArtistNamed('Rowdy Rebel'), reason: 'no id for this one: found by its name');
  });

  test('a copy without ids gives way to one with them, and plain YouTube never opens by id', () {
    final t = track([copy('youtube', 'v', ids: ['UCchannel']), copy('jiosaavn', 'b'), copy('ytmusic', 'c', ids: ['UCpop'])]);
    expect(artistOf(t, 'pop smoke'), const ArtistTarget(ArtistRef(source: 'ytmusic', id: 'UCpop', name: 'Pop Smoke')));
    expect(artistOf(null, 'Pop Smoke'), const ArtistNamed('Pop Smoke'));
  });

  test("the album opens the release the song's copy is on", () {
    final t = track([copy('jiosaavn', 'a', album: 'Meet The Woo', albumId: '17395837')]);
    expect(albumOf(t), const AlbumTarget(AlbumRef(source: 'jiosaavn', id: '17395837', title: 'Meet The Woo')));
    expect(albumOf(track([copy('jiosaavn', 'b', album: 'Meet The Woo')])), const AlbumNamed('Meet The Woo', 'Pop Smoke'));
  });

  test('the ids survive being saved and read back (a download, the library cache)', () {
    final saved = Listing.fromJson(copy('ytmusic', 'c', ids: ['UCpop'], album: 'x', albumId: 'MPREb_x').toJson());
    expect(saved.artistIds, ['UCpop']);
    expect(saved.albumId, 'MPREb_x');
    expect(copy('jiosaavn', 'd').toJson().containsKey('artist_ids'), isFalse, reason: 'nothing sent that was never known');
  });
}
