import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';

/// Bring a library in from Spotify, as the Mac app does. The files are read on this device; only each song's title,
/// artists and length go to the server, which finds each song on its sources in the background (POST
/// /import/spotify) and is asked how far it has got. Two kinds of file: Exportify's CSV (one per playlist, "Liked Songs"
/// among them) and Spotify's own data download (YourLibrary.json for liked songs, Playlist1.json… for playlists).
class ImportSong {
  const ImportSong(this.title, this.artists, [this.durationMs, this.youtubeId]);
  final String title; // empty for a YouTube video named only by its id
  final List<String> artists;
  final int? durationMs;
  final String? youtubeId;
  Map<String, dynamic> toJson() =>
      {'title': title, 'artists': artists, 'duration_ms': ?durationMs, 'youtube_id': ?youtubeId};
}

/// One list to import: into [playlistId] (an existing playlist), else a new playlist [name], else Liked Songs.
/// [youtubePlaylist] is a YouTube or YouTube Music playlist link, read by the server.
class ImportGroup {
  const ImportGroup(this.name, this.songs, {this.playlistId, this.youtubePlaylist});
  final String? name;
  final List<ImportSong> songs;
  final String? playlistId, youtubePlaylist;
  ImportGroup into(String playlist) => ImportGroup(name, songs, playlistId: playlist, youtubePlaylist: youtubePlaylist);
  Map<String, dynamic> toJson() => {
        'name': ?name,
        'playlist_id': ?playlistId,
        'youtube_playlist': ?youtubePlaylist,
        'songs': [for (final s in songs) s.toJson()],
      };
}

class ImportStatus {
  ImportStatus.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      total = (j['total'] as num).toInt(),
      done = (j['done'] as num).toInt(),
      added = (j['added'] as num).toInt(),
      missing = [for (final m in j['missing'] as List) m as String],
      finished = j['finished'] as bool,
      failed = j['failed'] as String?;
  final String id;
  final int total, done, added;
  final List<String> missing;
  final bool finished;
  final String? failed;
}

class UnreadableFile implements Exception {
  UnreadableFile(this.file);
  final String file;
  @override
  String toString() =>
      '“$file” is not a file from Exportify, Spotify\'s data download or Google Takeout.';
}

/// The lists in one picked file. A list named like Liked Songs goes to your liked songs.
List<ImportGroup> importGroups(String fileName, String text) {
  final dot = fileName.lastIndexOf('.');
  final base = dot > 0 ? fileName.substring(0, dot) : fileName;
  final groups = fileName.toLowerCase().endsWith('.csv')
      ? _exportify(text, base)
      : _spotifyJson(text);
  if (groups == null || groups.isEmpty) throw UnreadableFile(fileName);
  return groups;
}

/// A CSV: Exportify's (a header row naming "Track Name", "Artist Name(s)", "Duration (ms)") or Google Takeout's (a
/// "Video ID" column; "Song Title" and "Artist Name 1" in the music library's file). One row per song.
List<ImportGroup>? _exportify(String text, String name) {
  if (text.startsWith('\uFEFF')) text = text.substring(1); // a byte-order mark would hide the first column's name
  final rows = csvRows(text);
  if (rows.isEmpty) return null;
  final header = [for (final h in rows.first) h.trim()];
  int column(List<String> names) => header.indexWhere((h) => names.any(h.startsWith));
  final title = column(['Track Name', 'Song Title', 'Title']), artists = column(['Artist Name']);
  final video = column(['Video ID', 'Video Id']), duration = column(['Duration']);
  if (video < 0 && (title < 0 || artists < 0)) return null;
  String? cell(List<String> row, int i) => i >= 0 && i < row.length && row[i].isNotEmpty ? row[i] : null;
  final songs = <ImportSong>[];
  for (final row in rows.skip(1)) {
    final id = cell(row, video), named = cell(row, title);
    final youtubeId = id != null && id.length == 11 ? id : null;
    if (youtubeId == null && named == null) continue;
    // Exportify separates artists with ";" and a name may hold a comma ("Tyler, The Creator"): never split on ","
    final who = [for (final a in (cell(row, artists) ?? '').split(';')) if (a.trim().isNotEmpty) a.trim()];
    songs.add(ImportSong(named ?? '', who, int.tryParse(cell(row, duration) ?? ''), youtubeId));
  }
  var plain = name.replaceAll('_', ' ');
  if (plain.endsWith('-videos')) plain = plain.substring(0, plain.length - '-videos'.length); // Takeout's file names
  return [ImportGroup(plain.toLowerCase().contains('liked') ? null : plain, songs)];
}

/// Spotify's data download: YourLibrary.json ({"tracks": [{"track", "artist"}]}) or a playlists file
/// ({"playlists": [{"name", "items": [{"track": {"trackName", "artistName"}}]}]}). Neither gives a song's length.
List<ImportGroup>? _spotifyJson(String text) {
  final Object? root;
  try {
    root = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (root is! Map<String, dynamic>) return null;
  final tracks = root['tracks'];
  if (tracks is List) {
    return [
      ImportGroup(null, [
        for (final t in tracks)
          if (t is Map &&
              t['track'] is String &&
              (t['track'] as String).isNotEmpty)
            ImportSong(t['track'] as String, [
              if (t['artist'] is String) t['artist'] as String,
            ]),
      ]),
    ];
  }
  final playlists = root['playlists'];
  if (playlists is List) {
    final groups = <ImportGroup>[];
    for (final p in playlists) {
      if (p is! Map || p['name'] is! String || (p['name'] as String).isEmpty) continue;
      final songs = [
        for (final item in (p['items'] as List? ?? const []))
          // podcast episodes and local files have no "track": skipped
          if (item is Map &&
              item['track'] is Map &&
              (item['track']['trackName'] as String? ?? '').isNotEmpty)
            ImportSong(item['track']['trackName'] as String, [
              if (item['track']['artistName'] is String)
                item['track']['artistName'] as String,
            ]),
      ];
      if (songs.isNotEmpty) groups.add(ImportGroup(p['name'] as String, songs));
    }
    return groups;
  }
  return null;
}

/// RFC 4180: fields split by commas; a quoted field may hold commas, line breaks and doubled quotes.
List<List<String>> csvRows(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"' && field.isEmpty) {
      quoted = true;
    } else if (c == ',') {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows.where((r) => !(r.length == 1 && r.first.isEmpty)).toList();
}

/// The running or last import of this session, as the server last reported it.
class SpotifyImporter extends ChangeNotifier {
  SpotifyImporter._();
  static final shared = SpotifyImporter._();

  ImportStatus? status;
  String? problem;
  bool get running => status != null && !status!.finished;

  /// Starts an import of these files ((name, text) pairs), into [playlistId] when given, then asks every 2 s until
  /// the server has finished. [done] runs once at the end (the library shows what was added).
  Future<void> start(List<(String, String)> files, {String? playlistId, Future<void> Function()? done}) async {
    problem = null;
    final List<ImportGroup> groups;
    try {
      groups = [
        for (final (name, text) in files)
          for (final g in importGroups(name, text)) playlistId == null ? g : g.into(playlistId),
      ];
    } catch (e) {
      problem = e.toString();
      notifyListeners();
      return;
    }
    await _run(groups, done);
  }

  /// A YouTube or YouTube Music playlist link: to a new playlist named after it, or into [playlistId].
  Future<void> startLink(String link, {String? playlistId, Future<void> Function()? done}) async {
    problem = null;
    await _run([ImportGroup(null, const [], playlistId: playlistId, youtubePlaylist: link.trim())], done);
  }

  Future<void> _run(List<ImportGroup> groups, Future<void> Function()? done) async {
    // the last import's result goes at once: shown until the server answered, it read as this import's (12 Oct)
    status = null;
    notifyListeners();
    try {
      status = ImportStatus.fromJson(
        await Api.startSpotifyImport([for (final g in groups) g.toJson()]),
      );
    } catch (e) {
      problem = e.toString();
      notifyListeners();
      return;
    }
    notifyListeners();
    while (status != null && !status!.finished) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        status = ImportStatus.fromJson(
          await Api.spotifyImportStatus(status!.id),
        );
        notifyListeners();
      } catch (_) {} // asked again in 2 s
    }
    await done?.call();
  }
}
