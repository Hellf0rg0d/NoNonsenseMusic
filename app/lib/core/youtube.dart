import 'dart:convert';

import 'package:http/http.dart' as http;

/// Resolves YouTube audio links on the device, without going through the server.
///
/// A signed YouTube link carries the asking device's IP address, so a link the server fetched plays only on the
/// server's network. Looking the link up from the device lets a server anywhere still serve YouTube songs and keeps
/// YouTube lookups off the server. The server's /play endpoint (Api.audioUrl) stays the fallback. The same approach
/// is used by the Mac app's YouTubeLookup.swift.
///
/// One anonymous visitor id from YouTube's home page (kept in memory while the app runs), then one request to the
/// player API as YouTube's visionOS app, the client yt-dlp uses (no JavaScript, no PO token). No cookies are kept.
/// When YouTube changes this client, update [_client] from yt-dlp's `_base.py` ('visionos').
class YouTubeLookup {
  static final instance = YouTubeLookup();

  static const _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
  static const _client = {
    'clientName': 'VISIONOS', 'clientVersion': '1.02', 'deviceMake': 'Apple', 'deviceModel': 'RealityDevice17,1',
    'userAgent': _userAgent, 'osName': 'visionOS', 'osVersion': '26.5.23O471', 'hl': 'en',
  };
  /// itag 140 is AAC in an MP4 file, which every player here plays (Apple's players cannot play YouTube's default Opus in WebM).
  static const _aacItag = 140;

  /// Whether a source's copies are YouTube videos, whose links are looked up here: "ytmusic" and plain "youtube".
  static bool resolvesOnDevice(String source) => source == 'ytmusic' || source == 'youtube';

  http.Client client = http.Client(); // replaceable in tests
  String? _visitorId;
  final _links = <String, ({String url, DateTime until})>{}; // video id -> its link, valid until just before it expires

  /// Return the audio link for a YouTube video id.
  ///
  /// [fresh] skips the remembered link, which failed to play.
  Future<String> audioUrl(String videoId, {bool fresh = false}) async {
    final known = _links[videoId];
    if (!fresh && known != null && known.until.isAfter(DateTime.now())) return known.url;
    try {
      return await _lookUp(videoId);
    } on YouTubeLookupError catch (e) {
      if (e.status != 'LOGIN_REQUIRED' || _visitorId == null) rethrow;
      _visitorId = null; // the visitor id went stale; retry once with a new one
      return _lookUp(videoId);
    }
  }

  /// Forget a link that failed to play, so the next request looks it up again.
  void forget(String videoId) => _links.remove(videoId);

  /// Look up the next songs ahead of time, one at a time, skipping links already known.
  Future<void> warm(Iterable<String> videoIds) async {
    for (final id in videoIds) {
      final known = _links[id];
      if (known != null && known.until.isAfter(DateTime.now())) continue;
      try {
        await audioUrl(id);
      } catch (_) {}
    }
  }

  Future<String> _lookUp(String videoId) async {
    final visitor = await _currentVisitorId();
    final r = await client
        .post(Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
            headers: {
              'Content-Type': 'application/json', 'User-Agent': _userAgent, 'X-Goog-Visitor-Id': visitor,
              'X-Youtube-Client-Name': '101', 'X-Youtube-Client-Version': '1.02',
            },
            body: jsonEncode({
              'context': {'client': {..._client, 'visitorData': visitor}},
              'videoId': videoId, 'contentCheckOk': true, 'racyCheckOk': true,
            }))
        .timeout(const Duration(seconds: 10));
    final reply = jsonDecode(r.body) as Map<String, dynamic>;
    final status = (reply['playabilityStatus'] as Map?)?['status'] as String? ?? 'no status';
    if (status != 'OK') throw YouTubeLookupError(status);
    final formats = ((reply['streamingData'] as Map?)?['adaptiveFormats'] as List?) ?? const [];
    final aac = formats.cast<Map>().where((f) => f['itag'] == _aacItag && f['url'] is String).firstOrNull;
    if (aac == null) throw YouTubeLookupError('no AAC audio');
    final url = aac['url'] as String;
    _links[videoId] = (url: url, until: _usableUntil(url));
    return url;
  }

  Future<String> _currentVisitorId() async {
    final known = _visitorId;
    if (known != null) return known;
    final page = await client.get(Uri.parse('https://www.youtube.com/'), headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 10));
    final m = RegExp(r'"VISITOR_DATA":"([^"]+)"').firstMatch(page.body);
    if (m == null) throw YouTubeLookupError('no visitor id');
    return _visitorId = m.group(1)!;
  }

  /// Return when the link stops being usable: 10 minutes before the link's own `expire` (seconds since 1970), or 1 hour from now when it has none.
  static DateTime _usableUntil(String url) {
    final expire = int.tryParse(Uri.parse(url).queryParameters['expire'] ?? '');
    return expire == null
        ? DateTime.now().add(const Duration(hours: 1))
        : DateTime.fromMillisecondsSinceEpoch(expire * 1000).subtract(const Duration(minutes: 10));
  }
}

/// An error reported while looking up a YouTube audio link.
class YouTubeLookupError implements Exception {
  final String status;
  YouTubeLookupError(this.status);
  @override
  String toString() => 'YouTube: $status';
}
