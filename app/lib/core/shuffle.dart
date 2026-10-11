import 'dart:math';

/// Provide the two shuffling strategies used for playlists.
///
/// One is uniform random ordering; the other spreads each artist's songs through the list,
/// following Spotify's 2014 approach as implemented in the Mac app's Shuffle.swift.
class Shuffle {
  /// Return a uniformly random permutation of [items] using the Fisher–Yates algorithm.
  ///
  /// Every ordering of [items] is equally likely. A new list is returned; [items] is not modified.
  static List<T> fisherYates<T>(List<T> items, Random rng) {
    final result = [...items];
    for (var i = result.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final t = result[i];
      result[i] = result[j];
      result[j] = t;
    }
    return result;
  }

  /// Return a copy of [items] with the songs of each artist spread evenly through the list.
  ///
  /// Songs are grouped by the key that [artist] returns for them. An artist with k songs is
  /// assigned positions offset + i/k + jitter for i from 0 to k-1, where offset is chosen at
  /// random in [0, 1/k) and jitter lies within +/-0.1/k, so the songs land at even intervals
  /// with a little irregularity. Songs within an artist are ordered by [fisherYates] before
  /// placement.
  static List<T> artistSpread<T>(List<T> items, String Function(T) artist, Random rng) {
    final byArtist = <String, List<T>>{};
    for (final item in items) {
      byArtist.putIfAbsent(artist(item), () => []).add(item);
    }
    final placed = <(double, T)>[];
    for (final songs in byArtist.values) {
      final k = songs.length.toDouble();
      final offset = rng.nextDouble() / k;
      final shuffled = fisherYates(songs, rng);
      for (var i = 0; i < shuffled.length; i++) {
        final jitter = (rng.nextDouble() * 0.2 - 0.1) / k;
        placed.add((offset + i / k + jitter, shuffled[i]));
      }
    }
    placed.sort((a, b) => a.$1.compareTo(b.$1));
    return placed.map((p) => p.$2).toList();
  }
}
