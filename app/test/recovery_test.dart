// Recovery codes: shown once after sign-up, a wrong password is not a sign-out, and a password reset with a code.
// HTTP requests are answered by a mock client. All data is made up.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nononsense/core/account_api.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/ui/recovery_codes.dart';

const codes = [
  'AAAA-BBBB-CCCC-DDDD', 'EEEE-FFFF-GGGG-HHHH', 'IIII-JJJJ-KKKK-LLLL', 'MMMM-NNNN-OOOO-PPPP', 'QQQQ-RRRR-SSSS-TTTT',
  'UUUU-VVVV-WWWW-XXXX', 'YYYY-ZZZZ-1111-2222', '3333-4444-5555-6666', '7777-8888-9999-0000', 'ABCD-EFGH-IJKL-MNOP',
];

http.Response json(Object body, int status) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  setUp(() => Api.base = 'http://server.test');
  tearDown(() {
    Api.client = http.Client();
    Api.token = null;
    Api.onSignedOut = null;
  });

  test('a new account is handed its ten codes once, to show', () async {
    Api.client = MockClient((r) async => json({'token': 't', 'user': {'id': 'u1', 'username': 'kai'}, 'recovery_codes': codes}, 201));
    final auth = Auth(store: MemoryTokenStore());
    expect(await auth.signIn('kai', 'a test password', create: true), isNull);
    expect(auth.codesToShow, codes);
    auth.codesShown();
    expect(auth.codesToShow, isNull);
    Api.client = MockClient((r) async => json({'token': 't', 'user': {'id': 'u1', 'username': 'kai'}}, 200));
    await auth.signIn('kai', 'a test password');
    expect(auth.codesToShow, isNull, reason: 'signing in again shows no codes');
  });

  test('a wrong password for new codes says so and does not sign out', () async {
    var signedOut = 0;
    Api.onSignedOut = () => signedOut++;
    Api.token = 'live-token';
    Api.client = MockClient((r) async => json({'detail': 'Invalid credentials'}, 401));
    await expectLater(AccountApi.newCodes('wrong'), throwsA(isA<ApiError>().having((e) => e.toString(), 'text', 'Wrong password.')));
    expect(signedOut, 0);
    expect(Api.token, 'live-token');
  });

  test('a reset sends the username, code, new password and device, and signs this device in', () async {
    late Map<String, dynamic> sent;
    Api.client = MockClient((r) async {
      sent = jsonDecode(r.body) as Map<String, dynamic>;
      expect((r.url.path, r.headers.containsKey('authorization')), ('/auth/recover', false));
      return json({'token': 'new', 'user': {'id': 'u1', 'username': 'kai'}}, 200);
    });
    final auth = Auth(store: MemoryTokenStore());
    expect(await auth.recover('kai', codes.first, 'a new password', device: 'Kai Laptop'), isNull);
    expect(sent, {'username': 'kai', 'code': codes.first, 'new_password': 'a new password', 'device_name': 'Kai Laptop'});
    expect((auth.state, Api.token), (AuthState.signedIn, 'new'));
  });

  test('a wrong code shows the server\'s reason', () async {
    Api.client = MockClient((r) async => json({'detail': 'Wrong username or recovery code'}, 401));
    expect(await Auth(store: MemoryTokenStore()).recover('kai', 'nope', 'a new password'), 'Wrong username or recovery code');
  });

  testWidgets('the codes dialog cannot be dismissed, and Done waits for Copy', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) => TextButton(onPressed: () => showRecoveryCodes(c, codes, 'kai'), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'fits 360 wide');
    expect(find.text('Save Your Recovery Codes'), findsOneWidget);
    expect(find.textContaining('a code lets you set a new one'), findsOneWidget);
    expect(find.text(codes.first), findsOneWidget);
    expect(find.text(codes.last), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Done')).onPressed, isNull);

    await tester.tapAt(const Offset(2, 2)); // the barrier
    await tester.pumpAndSettle();
    expect(find.text('Save Your Recovery Codes'), findsOneWidget, reason: 'not dismissable');

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, contains(codes.first));
    expect(copied, contains('kai'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Save Your Recovery Codes'), findsNothing);
  });
}
