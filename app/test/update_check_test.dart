import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nononsense/core/update_check.dart';

void main() {
  test('versions compare number by number', () {
    expect(isNewer('0.3.0', '0.2.0'), isTrue);
    expect(isNewer('0.10.0', '0.9.1'), isTrue, reason: 'not as text: "0.10" sorts before "0.9"');
    expect(isNewer('0.2.0', '0.2.0'), isFalse);
    expect(isNewer('0.2', '0.2.0'), isFalse);
    expect(isNewer('0.1.9', '0.2.0'), isFalse);
  });

  http.Client github(int status, [String tag = 'v0.3.0']) => MockClient((r) async => http.Response(
      jsonEncode({'tag_name': tag, 'html_url': 'https://github.com/ego004/NoNonsenseMusic/releases/tag/$tag'}), status));

  test('a newer release is offered with its page; the same one, a skipped one or no answer is not', () async {
    final update = await checkForUpdate(current: '0.2.0', client: github(200));
    expect((update?.version, update?.page.path), ('0.3.0', '/ego004/NoNonsenseMusic/releases/tag/v0.3.0'));
    expect(await checkForUpdate(current: '0.3.0', client: github(200)), isNull);
    expect(await checkForUpdate(current: '0.2.0', skipped: '0.3.0', client: github(200)), isNull);
    expect(await checkForUpdate(current: '0.2.0', client: github(404)), isNull, reason: 'a private repository answers 404');
  });
}
