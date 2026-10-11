// A real JioSaavn song is fetched into the cache, and the second play finds its file:
//   flutter test test/audio_cache_server_test.dart --dart-define=SERVER=http://127.0.0.1:8771
// Skipped without SERVER. Never against port 8000.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/audio_cache.dart';
import 'package:nononsense/core/audio_download.dart';

import 'test_account.dart';

const server = String.fromEnvironment('SERVER');

void main() {
  final skip = server.isEmpty || server.contains(':8000') ? 'needs --dart-define=SERVER=<a test server>' : null;
  test('a played JioSaavn song lands in the cache as a file, and the second play uses it', () async {
    await signUpTestAccount();
    final dir = Directory.systemTemp.createTempSync('audio_live');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = AudioCache(Directory('${dir.path}/Audio')..createSync());
    final fetches = AudioDownloads(cache: cache);
    final songs = await Api.search('tum hi ho arijit singh');
    final listing = songs.firstWhere((t) => t.best.source == 'jiosaavn').best;
    expect(cache.peek(listing.key), isNull);

    final link = Uri.parse(await Api.audioUrl(listing));
    final download = fetches.fetch(listing.key, link);
    await download.whole();
    expect(download.isComplete, isTrue);
    final file = cache.peek(listing.key)!;
    final bytes = file.lengthSync();
    // ignore: avoid_print
    print('cached ${listing.key}: $bytes bytes at ${file.path}');
    expect(bytes, greaterThan(500000));

    // second play: the file is found, and no network is needed to find it
    Api.base = 'http://127.0.0.1:1'; // unreachable
    expect(cache.file(listing.key)!.lengthSync(), bytes);
  }, skip: skip);
}
