import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';

/// Bring a library in from Spotify, as the Mac app does. The files are read on this device; only each song's title,
/// artists and length go to the server, which finds each song on its sources in the background (POST
/// /import/spotify) and is asked how far it has got. Two kinds of file: Exportify's CSV (one per playlist, "Liked Songs"
/// among them) and Spotify's own data download (YourLibrary.json for liked songs, Playlist1.json… for playlists).
class ImportSong {
  const ImportSong(this.title, this.artists, [this.durationMs]);
  final String title;
  final List<String> artists;
  final int? durationMs;
  Map<String, dynamic> toJson() => {
    'title': title,
    'artists': artists,
    'duration_ms': ?durationMs,
  };
}

/// One list from a file: [name] null is Liked Songs, otherwise a new playlist of that name.
class ImportGroup {
  const ImportGroup(this.name, this.songs);
  final String? name;
  final List<ImportSong> songs;
  Map<String, dynamic> toJson() => {
    'name': ?name,
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
      '“$file” is not a file from Exportify or from Spotify\'s data download.';
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

/// Exportify: a header row naming the columns ("Track Name", "Artist Name(s)", "Duration (ms)"), one row per song.
List<ImportGroup>? _exportify(String text, String name) {
  final rows = csvRows(text);
  if (rows.isEmpty) return null;
  final header = rows.first;
  final title = header.indexWhere((h) => h.trim() == 'Track Name');
  final artists = header.indexWhere((h) => h.startsWith('Artist Name'));
  final duration = header.indexWhere((h) => h.startsWith('Duration'));
  if (title < 0 || artists < 0) return null;
  final songs = [
    for (final row in rows.skip(1))
      if (row.length > (title > artists ? title : artists) &&
          row[title].isNotEmpty)
        ImportSong(
          row[title],
          [
            for (final a in row[artists].split(','))
              if (a.trim().isNotEmpty) a.trim(),
          ],
          duration >= 0 && row.length > duration
              ? int.tryParse(row[duration])
              : null,
        ),
  ];
  final plain = name.replaceAll('_', ' ');
  return [
    ImportGroup(plain.toLowerCase().contains('liked') ? null : plain, songs),
  ];
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

  /// Starts an import of these files ((name, text) pairs), then asks every 2 s until the server has finished.
  /// [done] runs once at the end (the library shows what was added).
  Future<void> start(
    List<(String, String)> files, {
    Future<void> Function()? done,
  }) async {
    problem = null;
    final List<ImportGroup> groups;
    try {
      groups = [for (final (name, text) in files) ...importGroups(name, text)];
    } catch (e) {
      problem = e.toString();
      notifyListeners();
      return;
    }
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
