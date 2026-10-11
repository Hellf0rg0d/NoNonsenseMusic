import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One bounded piece of a file: its bytes, and the whole file's length when the server said it.
class RangeChunk {
  const RangeChunk(this.data, this.total);
  final Uint8List data;
  final int? total;
}

/// The server answered a bounded range with the whole file (200) past the first byte, or with an error status.
/// Retrying would fetch the whole file again, so it is never retried.
class RangeRefused implements Exception {
  RangeRefused(this.status);
  final int status;
  @override
  String toString() => 'The audio server refused a ranged request (status $status).';
}

/// Fetches audio in bounded ranges. YouTube serves an open-ended request (`bytes=0-`) at about playback speed, so a
/// whole song takes as long to fetch as to play; bounded ranges come at full speed, and JioSaavn's CDN honours them
/// too. The first range is small so that sound can start at once, the rest are 1 MB each.
class RangeFetcher {
  RangeFetcher(this.client, {this.retryDelay = const Duration(milliseconds: 400)});

  final http.Client client;

  /// The wait before a failed range is asked again, multiplied by the attempt number.
  final Duration retryDelay;

  static const firstRange = 256 * 1024;
  static const range = 1024 * 1024;

  /// Fetches bytes [from] to [to], both included, in one attempt.
  Future<RangeChunk> fetch(Uri link, int from, int to) async {
    final request = http.Request('GET', link)..headers['range'] = 'bytes=$from-$to';
    final response = await client.send(request).timeout(const Duration(seconds: 15));
    final status = response.statusCode;
    // Past the first byte only a 206 is the asked range; a 200 there is the whole file again, so its body is not read.
    if (status != 206 && !(status == 200 && from == 0)) {
      response.stream.listen(null).cancel();
      throw RangeRefused(status);
    }
    final data = await response.stream.toBytes().timeout(const Duration(seconds: 30));
    final fromHeader = response.headers['content-range']?.split('/').last;
    return RangeChunk(data, status == 200 ? data.length : int.tryParse(fromHeader ?? ''));
  }

  /// Like [fetch], asking a failed range again twice (a dropped connection mid-song) before giving up.
  Future<RangeChunk> fetchWithRetry(Uri link, int from, int to) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await fetch(link, from, to);
      } on RangeRefused {
        rethrow;
      } catch (_) {
        if (attempt > 2) rethrow;
        await Future<void>.delayed(retryDelay * attempt);
      }
    }
  }
}
