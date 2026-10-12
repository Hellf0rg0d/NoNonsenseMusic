import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'audio_cache.dart';
import 'audio_download.dart';
import 'models.dart';
import 'range_fetcher.dart';

/// A downloaded song: the copy that was fetched, and the song as the app showed it, so the list works with no server.
class DownloadItem {
  DownloadItem({required this.key, required this.file, required this.best, required this.listings, this.image,
      required this.bytes, required this.added});

  final String key; // the downloaded copy: "source:id"
  final String file; // its name in the folder
  final Listing best;
  final List<Listing> listings;
  /// The song's cover as shown when it was downloaded.
  final String? image;
  final int bytes;
  final DateTime added;

  Track get track => Track(best, listings, image: image, choosingVersion: false);

  Map<String, dynamic> toJson() => {
        'key': key, 'file': file, 'best': best.toJson(), 'listings': [for (final l in listings) l.toJson()],
        'image': image, 'bytes': bytes, 'added': added.toIso8601String(),
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
        key: j['key'] as String,
        file: j['file'] as String,
        best: Listing.fromJson(j['best'] as Map<String, dynamic>),
        listings: [for (final l in j['listings'] as List) Listing.fromJson(l as Map<String, dynamic>)],
        image: j['image'] as String?,
        bytes: (j['bytes'] as num).toInt(),
        added: DateTime.parse(j['added'] as String),
      );
}

/// Songs kept on this device to play with no server and no internet. The files live in their own folder beside an
/// `index.json` with each song's details. A download is never evicted, unlike the audio cache: only the user removes it.
class DownloadStore extends ChangeNotifier {
  DownloadStore({AudioCache? cache, AudioDownloads? fetches, RangeFetcher? fetcher, Future<Uri> Function(Listing)? linkFor,
      http.Client? client})
      : cache = cache ?? AudioCache.shared,
        _http = client ?? http.Client(),
        fetches = fetches ?? AudioDownloads.shared,
        fetcher = fetcher ?? RangeFetcher(http.Client()),
        linkFor = linkFor ?? _serverLink;

  static final shared = DownloadStore();

  final AudioCache cache;
  final AudioDownloads fetches;
  final RangeFetcher fetcher;
  final Future<Uri> Function(Listing) linkFor;
  final http.Client _http; // covers

  static Future<Uri> _serverLink(Listing l) async => Uri.parse(await Api.audioUrl(l));

  Directory? folder;

  /// Newest first.
  List<DownloadItem> items = [];

  /// Songs being downloaded now (by Track.id).
  final inProgress = <String>{};

  /// Called after each song is downloaded: the app keeps its lyrics beside it (LyricsStore.keep).
  Future<void> Function(Track)? onDownloaded;

  /// Kept covers by cover address: a downloaded song's cover shows from its file, also offline (coverProvider).
  /// Before 12 Oct no cover was kept, and Image.network keeps none on disk: offline, downloads had none.
  final _covers = <String, File>{};

  int get totalBytes => items.fold(0, (sum, i) => sum + i.bytes);

  /// Opens the downloads folder and reads the index. On Windows it sits beside the cache in the local profile, not
  /// the roaming one, which a managed PC copies to a server at every sign-out.
  Future<void> load([Directory? at]) async {
    final base = at ?? Directory('${(Platform.isWindows ? await getApplicationCacheDirectory() : await getApplicationSupportDirectory()).path}/Downloads');
    await base.create(recursive: true);
    folder = base;
    try {
      final saved = (jsonDecode(await File('${base.path}/index.json').readAsString()) as List)
          .map((j) => DownloadItem.fromJson(j as Map<String, dynamic>));
      // a file removed by hand is no longer a download
      items = saved.where((i) => File('${base.path}/${i.file}').existsSync()).toList();
    } catch (_) {
      items = [];
    }
    for (final i in items) {
      final f = _coverFile(i);
      if (i.image != null && f.existsSync()) _covers[i.image!] = f;
    }
    notifyListeners();
  }

  /// The downloaded item for this song, if any of its copies is downloaded.
  DownloadItem? item(Track t) {
    for (final i in items) {
      if (t.listings.any((l) => l.key == i.key)) return i;
    }
    return null;
  }

  bool isDownloaded(Track t) => item(t) != null;
  bool isDownloading(Track t) => inProgress.contains(t.id);

  /// The file to play for this song: of any copy, or only of [copy] when the user chose one.
  File? fileFor(Track t, {Listing? copy}) {
    final i = item(t);
    if (i == null || (copy != null && copy.key != i.key)) return null;
    return File('${folder!.path}/${i.file}');
  }

  /// Downloads the song: its playing copy, else its other copies in turn. Copies from the cache when the song is
  /// there, otherwise fetches in bounded ranges. Returns whether the song is downloaded.
  Future<bool> download(Track t) async {
    if (folder == null) return false;
    if (isDownloaded(t)) return true;
    if (!inProgress.add(t.id)) return true;
    notifyListeners();
    try {
      for (final l in [t.best, ...t.listings.where((l) => l.key != t.best.key)]) {
        try {
          final name = '${l.source}-${l.id}'.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_');
          final target = File('${folder!.path}/$name.m4a');
          if (!await _copyFromCache(l.key, target) && !await _fetch(l, target)) continue;
          items.insert(0, DownloadItem(key: l.key, file: '$name.m4a', best: t.best, listings: t.listings, image: t.image,
              bytes: await target.length(), added: DateTime.now()));
          await _save();
          await _keepCover(items.first);
          await onDownloaded?.call(t);
          return true;
        } catch (_) {
          continue;
        }
      }
      return false;
    } finally {
      inProgress.remove(t.id);
      notifyListeners();
    }
  }

  /// Downloads every song not downloaded yet, one at a time. Returns how many were downloaded.
  Future<int> downloadAll(List<Track> tracks) async {
    var done = 0;
    for (final t in tracks.where((t) => !isDownloaded(t))) {
      if (await download(t)) done++;
    }
    return done;
  }

  Future<void> remove(Track t) async {
    final i = item(t);
    if (i == null) return;
    await _delete(i);
    items.remove(i);
    await _save();
    notifyListeners();
  }

  Future<void> removeAll() async {
    for (final i in items) {
      await _delete(i);
    }
    items = [];
    await _save();
    notifyListeners();
  }

  /// A downloaded file that would not play is dropped from the list.
  Future<void> dropFile(File f) async {
    final gone = items.where((i) => File('${folder!.path}/${i.file}').path == f.path).toList();
    if (gone.isEmpty) return;
    for (final i in gone) {
      await _delete(i);
      items.remove(i);
    }
    await _save();
    notifyListeners();
  }

  Future<bool> _copyFromCache(String key, File target) async {
    // the song may be playing or queued next right now: its fetch is waited for, then it is in the cache
    await fetches.finished(key);
    final cached = cache.peek(key);
    if (cached == null) return false;
    await cached.copy(target.path);
    return true;
  }

  Future<bool> _fetch(Listing l, File target) async {
    final link = await linkFor(l);
    final download = AudioDownload(key: l.key, link: link, target: target, fetcher: fetcher);
    await fetches.background(download.whole);
    return download.isComplete;
  }

  Future<void> _delete(DownloadItem i) async {
    for (final f in [File('${folder!.path}/${i.file}'), _coverFile(i), _lyricsFile(i)]) {
      if (await f.exists()) await f.delete();
    }
    _covers.remove(i.image);
  }

  File _coverFile(DownloadItem i) => File('${folder!.path}/${i.file}.cover');
  File _lyricsFile(DownloadItem i) => File('${folder!.path}/${i.file}.lyrics.json');

  /// The kept cover for this cover address, if a download has one.
  File? keptCover(String url) => _covers[url];

  Future<void> _keepCover(DownloadItem i) async {
    final address = i.image;
    if (address == null || _covers.containsKey(address)) return;
    try {
      final r = await _http.get(Uri.parse(address)).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return;
      final f = _coverFile(i);
      await f.writeAsBytes(r.bodyBytes, flush: true);
      _covers[address] = f;
      notifyListeners();
    } catch (_) {} // offline now: keepMissingCovers tries again at the next start
  }

  /// Downloads made before covers were kept: each gets its cover once, while there is internet.
  Future<void> keepMissingCovers() async {
    for (final i in [...items]) {
      await _keepCover(i);
    }
  }

  /// The lyrics kept with a downloaded song, so they show offline.
  Future<Lyrics?> keptLyrics(Track t) async {
    final i = item(t);
    if (i == null || folder == null) return null;
    try {
      return Lyrics.fromJson(jsonDecode(await _lyricsFile(i).readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> keepLyrics(Track t, Lyrics lyrics) async {
    final i = item(t);
    if (i == null || folder == null || lyrics.lines.isEmpty) return;
    await _lyricsFile(i).writeAsString(jsonEncode(lyrics.toJson()));
  }

  Future<void> _save() async {
    final index = File('${folder!.path}/index.json');
    final temp = File('${index.path}.tmp');
    await temp.writeAsString(jsonEncode([for (final i in items) i.toJson()]));
    await temp.rename(index.path);
  }
}
