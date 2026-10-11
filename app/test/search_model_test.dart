// Search's state: the filter capsules, what each filter asks for, and which answer is kept. Answered by a stub.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/catalog.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/search_model.dart';

SearchResult result({int songs = 0, int artists = 0, int albums = 0}) => SearchResult(
      songs: [for (var i = 0; i < songs; i++) Track(Listing(source: 'jiosaavn', id: 's$i', title: 'Song $i', artists: const ['Kai'], duration: 100), const [])],
      artists: [for (var i = 0; i < artists; i++) SearchArtist('Artist $i', null, ArtistRef(source: 'jiosaavn', id: 'a$i', name: 'Artist $i'))],
      albums: [for (var i = 0; i < albums; i++) AlbumRef(source: 'jiosaavn', id: 'b$i', title: 'Album $i')],
    );

void main() {
  testWidgets('a filter asks the server for that kind, at once, and All asks for everything', (tester) async {
    final asked = <(String, String)>[];
    final m = SearchModel(ask: (q, f) async { asked.add((q, f)); return result(songs: 1); }, onSongs: (_) {});
    m.typed('kai');
    await tester.pump(const Duration(milliseconds: 349));
    expect(asked, isEmpty, reason: 'waits for typing to pause');
    await tester.pump(const Duration(milliseconds: 2));
    m.setFilter(SearchFilter.artists);
    m.setFilter(SearchFilter.albums);
    m.setFilter(SearchFilter.songs);
    m.setFilter(SearchFilter.all);
    await tester.pump();
    expect(asked, [('kai', 'all'), ('kai', 'artists'), ('kai', 'albums'), ('kai', 'songs'), ('kai', 'all')]);
  });

  testWidgets('choosing the filter already chosen asks nothing', (tester) async {
    var asked = 0;
    final m = SearchModel(ask: (q, f) async { asked++; return result(); }, onSongs: (_) {});
    m.typed('kai');
    await tester.pump(const Duration(seconds: 1));
    m.setFilter(SearchFilter.all);
    await tester.pump();
    expect(asked, 1);
  });

  testWidgets('only the newest question\'s answer is kept, even when an older one arrives last', (tester) async {
    final slow = Completer<SearchResult>(), fast = Completer<SearchResult>();
    final m = SearchModel(ask: (q, f) => f == 'all' ? slow.future : fast.future, onSongs: (_) {});
    m.typed('kai');
    await tester.pump(const Duration(seconds: 1));
    m.setFilter(SearchFilter.artists);
    fast.complete(result(artists: 3));
    await tester.pump();
    slow.complete(result(songs: 9));
    await tester.pump();
    expect((m.filter, m.artists.length, m.songs.length, m.loading), (SearchFilter.artists, 3, 0, false));
  });

  test('All shows 8 artists and 12 albums; a filter shows up to 60 of its kind', () {
    final m = SearchModel(ask: (q, f) async => result(artists: 70, albums: 70), onSongs: (_) {});
    m.result = result(artists: 70, albums: 70);
    expect((m.artists.length, m.albums.length), (8, 12));
    m.filter = SearchFilter.artists;
    expect((m.artists.length, m.albums.length), (60, 60));
  });

  testWidgets('clearing the field empties the results; a failure and an empty answer are told apart', (tester) async {
    var fail = true;
    final m = SearchModel(ask: (q, f) async => fail ? throw Exception('down') : result(), onSongs: (_) {});
    m.typed('kai');
    await tester.pump(const Duration(seconds: 1));
    expect((m.failed, m.showsNoResults), (true, false));
    fail = false;
    m.submit();
    await tester.pump();
    expect((m.failed, m.showsNoResults), (false, true));
    m.typed('');
    expect((m.isIdle, m.showsNoResults, m.result.isEmpty), (true, false, true));
  });
}
