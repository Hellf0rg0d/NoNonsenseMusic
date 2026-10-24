// Data models mirroring the server's JSON, plus Track, which every screen and the player use.
// The rules match those of the Mac app (mac/NoNonsense/Models/Models.swift).

/// One copy of a song on one source.
class Listing {
  final String source; // "jiosaavn" | "ytmusic" | "youtube"
  final String id;
  final String title;
  final List<String> artists;
  final String? album;
  final int duration;
  final int? popularity;
  final String? image;

  /// Whether this copy is the explicit version; null: not known.
  final bool? explicit;

  /// The source's id for each of [artists], in order (null for a name it gave no id), and for the album this copy is
  /// on: the pages to open. Null when the source said nothing (a copy stored before 24 Oct, or plain YouTube).
  final List<String?>? artistIds;
  final String? albumId;

  /// What the copy is, as its source says: "audio" (the song), "video" (its music video), "upload" (anyone's video);
  /// null: not known. A video can run longer than the song, so the song's lyrics' times fit only the song.
  final String? kind;

  const Listing({
    required this.source,
    required this.id,
    required this.title,
    required this.artists,
    this.album,
    required this.duration,
    this.popularity,
    this.image,
    this.explicit,
    this.artistIds,
    this.albumId,
    this.kind,
  });

  /// Unique across sources: the same id string could exist on two sources.
  String get key => '$source:$id';
  String get sourceName => nameOfSource(source);

  /// "jiosaavn" becomes "JioSaavn": the name shown for each source.
  static String nameOfSource(String source) =>
      switch (source) { 'jiosaavn' => 'JioSaavn', 'youtube' => 'YouTube', _ => 'YouTube Music' };

  /// The audio quality the source streams at, as Now Playing states it.
  String get quality => source == 'jiosaavn' ? 'AAC 320 kbps' : 'AAC 128 kbps';

  factory Listing.fromJson(Map<String, dynamic> j) => Listing(
        source: j['source'] as String,
        id: j['id'] as String,
        title: j['title'] as String,
        artists: (j['artists'] as List).cast<String>(),
        album: j['album'] as String?,
        duration: (j['duration'] as num).toInt(),
        popularity: (j['popularity'] as num?)?.toInt(),
        image: j['image'] as String?,
        explicit: j['explicit'] as bool?,
        artistIds: (j['artist_ids'] as List?)?.cast<String?>(),
        albumId: j['album_id'] as String?,
        kind: j['kind'] as String?,
      );

  /// Converts this object to a JSON map, a missing optional field as null.
  ///
  /// `album` and `popularity` are included even when null: the server answers 422 "Field required" when they are
  /// absent.
  Map<String, dynamic> toJson() => {
        'source': source,
        'id': id,
        'title': title,
        'artists': artists,
        'album': album,
        'duration': duration,
        'popularity': popularity,
        'image': image,
        'explicit': explicit,
        if (artistIds != null) 'artist_ids': artistIds,
        if (albumId != null) 'album_id': albumId,
        if (kind != null) 'kind': kind,
      };

  /// The song before a copy of unknown kind, before its music video, before an upload (the server's KIND_RANK).
  int get kindRank => switch (kind) { 'audio' => 0, null => 1, 'video' => 2, _ => 3 };
}

/// A song as every screen and the player work with it, built from a search or the library.
class Track {
  final String id; // the best listing's key
  final Listing best; // the copy to play
  final List<Listing> listings; // every copy: fallbacks, "N versions"

  /// The song's cover: the server's own, else the rule below. It never depends on which copy plays.
  final String? image;

  /// Settings › Playback › Version: true (the default) plays a song's explicit version when it has one.
  static bool prefersExplicit = true;

  /// Settings › Playback › Preferred Source: "jiosaavn", "ytmusic" or "youtube"; null is Automatic (the server's pick).
  static String? preferredSource;

  Track._(this.best, this.listings, this.image) : id = best.key;

  /// Builds the track with [best] set to the copy the user's preferences select, when [choosingVersion] is true.
  ///
  /// The preferred source's copies come first, then the server's pick, then the rest: the song before its video
  /// ([Listing.kindRank]: a video's views outnumber the song's plays, and its length the song's lyrics), then the most
  /// popular. The first
  /// preferred-source copy whose explicit flag matches [prefersExplicit] wins; then one of that source whose version
  /// is not known, since an unknown version does not contradict the choice; then any source's copy of the wanted
  /// version; with no match, or with [choosingVersion] false, [serverBest] is used. The remaining listings keep a
  /// stable order, which is the fallback order.
  ///
  /// [image] is the song's permanent cover. Without one the cover follows [cover], which depends only on the set of
  /// copies, so the cover of a song is the same whichever copy plays.
  factory Track(Listing serverBest, List<Listing> listings, {String? image, bool choosingVersion = true}) {
    final preferred = preferredSource ?? serverBest.source;
    int byPopularity(Listing a, Listing b) => (b.popularity ?? 0).compareTo(a.popularity ?? 0);
    List<Listing> ordered(Iterable<Listing> from, String first) {
      final indexed = from.indexed.toList()
        ..sort((a, b) {
          final r = (a.$2.source == first ? 0 : 1).compareTo(b.$2.source == first ? 0 : 1);
          if (r != 0) return r;
          final k = a.$2.kindRank.compareTo(b.$2.kindRank);
          if (k != 0) return k;
          final p = byPopularity(a.$2, b.$2);
          return p != 0 ? p : a.$1.compareTo(b.$1);
        });
      return [for (final e in indexed) e.$2];
    }

    final inOrder = [serverBest, ...ordered(listings, preferred)];
    final ranked = [...inOrder.where((l) => l.source == preferred), ...inOrder.where((l) => l.source != preferred)];
    Listing? firstWhereOrNull(bool Function(Listing) test) {
      for (final l in ranked) {
        if (test(l)) return l;
      }
      return null;
    }

    final best = choosingVersion
        ? firstWhereOrNull((l) => l.source == preferred && l.explicit == prefersExplicit) ??
            firstWhereOrNull((l) => l.source == preferred && l.explicit == null) ??
            firstWhereOrNull((l) => l.explicit == prefersExplicit) ??
            ranked.first
        : serverBest;
    final others = ordered(listings.where((l) => l.key != best.key), best.source);
    final cover = image != null && image.isNotEmpty ? image : Track.cover([best, ...listings]);
    return Track._(best, [best, ...others], cover);
  }

  /// The cover when the server sent none: its rule (matching.pick_cover). The most trusted source's picture wins,
  /// then the most popular copy's, then the smallest id, so the choice depends on the set of copies and never on
  /// their order.
  static String? cover(Iterable<Listing> listings) {
    const order = ['ytmusic', 'jiosaavn', 'youtube'];
    (int, int, String) rank(Listing l) {
      final i = order.indexOf(l.source);
      return (i < 0 ? order.length : i, -(l.popularity ?? 0), l.id);
    }

    Listing? best;
    for (final l in listings) {
      if (l.image == null || l.image!.isEmpty) continue;
      if (best == null) {
        best = l;
        continue;
      }
      final (a, b) = (rank(l), rank(best));
      final c = a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$3.compareTo(b.$3);
      if (c < 0) best = l;
    }
    return best?.image;
  }

  factory Track.fromSong(Map<String, dynamic> j) => Track(
        Listing.fromJson(j['best'] as Map<String, dynamic>),
        (j['listings'] as List).map((l) => Listing.fromJson(l as Map<String, dynamic>)).toList(),
        image: j['image'] as String?,
      );

  String get title => best.title;
  List<String> get artists => best.artists;
  String get artistLine => artists.join(', ');
  int get duration => best.duration;
  /// The album the best copy belongs to, when its source names one.
  String? get albumTitle => best.album == null || best.album!.isEmpty ? null : best.album;
  bool get isExplicit => best.explicit == true;

  /// The same song with [listing] as the copy to play, bypassing the version preference.
  Track playing(Listing listing) => Track(listing, listings, image: image, choosingVersion: false);

  /// Whether [other] is the same song, whichever copy plays: the sets of listing keys match.
  bool isSameSong(Track other) {
    if (id == other.id) return true;
    if (listings.length != other.listings.length) return false;
    return listings.map((l) => l.key).toSet().containsAll(other.listings.map((l) => l.key));
  }

  @override
  bool operator ==(Object other) => other is Track && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// A stored song (Liked, Recently Played): a [Track] with its id in the user's library.
class LibrarySong {
  final String songId;
  final Track track;
  LibrarySong(this.songId, this.track);
  factory LibrarySong.fromJson(Map<String, dynamic> j) => LibrarySong(j['id'] as String, Track.fromSong(j));
}

/// Formats [seconds] as "3:20", or "1:03:20" once an hour or more has elapsed.
///
/// Non-finite and non-positive input are formatted as 0.
String formatTime(double seconds) {
  final s = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
