// Browsing, pinning, radio and recovery codes against a test server, no window needed:
//   flutter test test/browse_server_test.dart --dart-define=SERVER=http://127.0.0.1:8765
// Skipped without SERVER. Never against port 8000, which serves the user's own library. Needs the sources (the
// internet) for the search, album, artist and radio calls.
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/account_api.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/catalog.dart';
import 'package:nononsense/core/library.dart';

import 'test_account.dart';

const server = String.fromEnvironment('SERVER');

void main() {
  final skip = server.isEmpty || server.contains(':8000') ? 'needs --dart-define=SERVER=<a test server>' : null;
  setUpAll(() async { if (skip == null) await signUpTestAccount(); });

  test('each filter answers its own kind, and a song carries its cover', () async {
    final all = await Catalog.search('arijit singh');
    expect(all.songs, isNotEmpty);
    expect(all.artists, isNotEmpty);
    expect(all.albums, isNotEmpty);
    expect(all.songs.first.image, isNotNull, reason: 'the song\'s own cover');
    final artists = await Catalog.search('arijit singh', filter: 'artists');
    expect(artists.songs, isEmpty);
    expect(artists.artists, isNotEmpty);
    final albums = await Catalog.search('arijit singh', filter: 'albums');
    expect(albums.songs, isEmpty);
    expect(albums.albums, isNotEmpty);
    final songs = await Catalog.search('arijit singh', filter: 'songs');
    expect(songs.songs, isNotEmpty);
    expect([songs.artists, songs.albums], [isEmpty, isEmpty]);
  }, skip: skip);

  test('an artist and an album open from a search, by name too; an album pins and unpins', () async {
    final ref = await Catalog.artistNamed('Arijit Singh');
    expect(ref, isNotNull);
    final artist = await Catalog.artist(ref!);
    expect(artist.songs, isNotEmpty);
    expect(artist.albums, isNotEmpty);

    final album = await Catalog.album(artist.albums.first);
    expect(album.songs, isNotEmpty);
    final byName = await Catalog.albumNamed(album.title, album.artists.firstOrNull ?? '');
    expect(byName, isNotNull);

    final library = Library();
    await library.refresh();
    expect(library.pinned(album.ref), isNull);
    expect(await library.pin(album.ref), isNull);
    final pinned = library.pinned(album.ref)!;
    expect((pinned.isAlbum, pinned.canEdit, library.pinnedAlbums.length), (true, false, 1));
    expect(await library.pin(album.ref), isNull, reason: 'pinned twice: the 409 counts as pinned');
    expect(library.pinnedAlbums.length, 1);
    final detail = await Api.playlist(pinned.id);
    expect(detail.items.length, greaterThan(0));
    expect(await library.unpin(pinned), isNull);
    expect(library.pinned(album.ref), isNull);
  }, skip: skip);

  test('radio gives songs like the seed, none of the excluded', () async {
    final seed = (await Catalog.search('arijit singh', filter: 'songs')).songs.first;
    final more = await Catalog.radio(seed.best, seed.listings);
    expect(more, isNotEmpty);
    expect(more.any((t) => t.listings.any((l) => seed.listings.any((s) => s.key == l.key))), isFalse);
  }, skip: skip);

  test('recovery codes: ten at sign-up, a wrong password is refused and keeps the session, a right one replaces the set', () async {
    final auth = await signUpTestAccount();
    expect(auth.codesToShow, hasLength(10));
    expect(await AccountApi.codesLeft(), 10);
    await expectLater(AccountApi.newCodes('not the password'), throwsA(isA<ApiError>().having((e) => e.toString(), 'text', 'Wrong password.')));
    expect(Api.token, isNotNull, reason: 'still signed in');
    expect(await AccountApi.codesLeft(), 10);
    final fresh = await AccountApi.newCodes('a test password');
    expect(fresh, hasLength(10));
    expect(fresh.toSet().intersection(auth.codesToShow!.toSet()), isEmpty);

    // a reset with a code: one use, then the old password no longer works
    final name = auth.user!.username;
    final back = Auth(store: MemoryTokenStore());
    expect(await back.recover(name, fresh.first, 'a brand new password'), isNull);
    expect(await back.recover(name, fresh.first, 'another password'), isNotNull, reason: 'each code works once');
  }, skip: skip);
}
