import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'audio_download.dart';
import 'range_fetcher.dart';

/// Serves songs being fetched to the player as ordinary URLs on this device's loopback address, answering byte
/// ranges from the AudioDownload's file as the bytes arrive. The player (Media Foundation on Windows, ExoPlayer on
/// Android, AVPlayer on the Mac preview) sees a plain `http://127.0.0.1` audio file, the path every platform plays
/// and just_audio_windows documents as tested, and the Mac preview can still clip the song to its listed length.
/// The server listens on a port that only this device can reach; nothing runs while no song is playing.
class LoopbackAudio {
  static final shared = LoopbackAudio();

  HttpServer? _server;
  final _routes = <String, AudioDownload>{};

  /// The address the player can open to hear [download].
  Future<Uri> serve(AudioDownload download) async {
    var server = _server;
    if (server == null) {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_handle, onError: (Object _) {});
      _server = server;
    }
    final id = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${math.Random().nextInt(1 << 30).toRadixString(36)}';
    _routes[id] = download;
    // the player holds one song at a time: older routes are not asked for again
    while (_routes.length > 4) {
      _routes.remove(_routes.keys.first);
    }
    return Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: '/a/$id.m4a');
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final id = request.uri.pathSegments.length == 2 ? request.uri.pathSegments[1].split('.').first : '';
      final download = _routes[id];
      if (download == null || (request.method != 'GET' && request.method != 'HEAD')) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final int length;
      try {
        length = await download.totalLength();
      } catch (_) {
        response.statusCode = HttpStatus.badGateway;
        return;
      }
      final match = RegExp(r'^bytes=(\d*)-(\d*)').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      final ranged = match != null && match.group(1)!.isNotEmpty;
      final from = ranged ? int.parse(match.group(1)!) : 0;
      final last = ranged && match.group(2)!.isNotEmpty ? math.min(int.parse(match.group(2)!), length - 1) : length - 1;
      if (from >= length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        return;
      }
      response.statusCode = ranged ? HttpStatus.partialContent : HttpStatus.ok;
      response.headers
        ..set(HttpHeaders.contentTypeHeader, 'audio/mp4')
        ..set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (ranged) response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-$last/$length');
      response.contentLength = last - from + 1;
      if (request.method == 'HEAD') return;
      for (var at = from; at <= last;) {
        final piece = await download.bytes(at, math.min(at + RangeFetcher.range, last + 1) - 1);
        if (piece.isEmpty) break;
        response.add(piece);
        await response.flush();
        at += piece.length;
      }
    } catch (_) {
      // the player closed the connection (a seek, a new song): nothing to answer
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }
}
