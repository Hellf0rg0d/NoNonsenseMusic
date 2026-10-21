// Why a sign-in failed, in its own words (21 Oct): an address the network cannot find, a certificate this device does
// not trust, a server too slow to answer, a refused connection, and a failure here after the server answered, which is
// not the network's. HTTP requests are answered by a mock client. All data is made up.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';

void main() {
  setUp(() => Api.base = 'https://server.test');
  tearDown(() => Api.client = http.Client());

  /// Makes an account while every request fails with [failure]: what the screen says, and whether it shows the
  /// server's address as unreachable.
  Future<(String?, bool)> signUpFailing(Object failure) async {
    Api.client = MockClient((r) async => throw failure);
    final auth = Auth(store: MemoryTokenStore());
    return (await auth.signIn('kai', 'a test password', create: true), auth.unreachable);
  }

  test('each network failure says what it was', () async {
    expect(await signUpFailing(const SocketException("Failed host lookup: 'server.test'")),
        ("Can't find the server. Check its address.", true));
    expect(await signUpFailing(const HandshakeException('Handshake error in client',
            OSError('CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate(handshake.cc:297)', 0))),
        ("This device doesn't trust the server's certificate. Check its date and time.", true));
    expect(await signUpFailing(const HandshakeException('Connection terminated during handshake')),
        ("Can't make a secure connection to the server.", true));
    expect(await signUpFailing(TimeoutException(null, const Duration(seconds: 20))),
        ("The server didn't answer in time.", true));
    expect(await signUpFailing(const SocketException('Connection refused')), ("Can't connect to the server.", true));
    expect(await signUpFailing(http.ClientException('Connection closed before full header was received')),
        ("Can't connect to the server.", true));
  });

  test('a failure after the server answered is not the network\'s', () async {
    Api.client = MockClient((r) async => http.Response('{"token": "t"}', 201)); // no user in the answer
    final auth = Auth(store: MemoryTokenStore());
    final said = await auth.signIn('kai', 'a test password', create: true);
    expect(said, startsWith('Something went wrong in the app: '));
    expect(auth.unreachable, isFalse);
  });

  test('the server\'s own reason still shows as it is', () async {
    Api.client = MockClient((r) async => http.Response('{"detail": "That username is taken"}', 409));
    final auth = Auth(store: MemoryTokenStore());
    expect((await auth.signIn('kai', 'a test password', create: true), auth.unreachable), ('That username is taken', false));
  });
}
