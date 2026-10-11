// The session token stored in a file on the Mac: readable by the user's own account alone, and taking over
// from the Keychain.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';

void main() {
  // The Mac and Linux stores, where these tests also run; Windows keeps its DPAPI store and has no chmod.
  final skip = Platform.isWindows ? 'the Mac app\'s store: Windows keeps flutter_secure_storage (DPAPI)' : null;
  late Directory folder;
  setUp(() async => folder = Directory('${(await Directory.systemTemp.createTemp('session')).path}/app'));
  tearDown(() => folder.parent.delete(recursive: true));

  test('the token is a file only you can read, in a folder only you can open; signing out deletes it', () async {
    final store = FileTokenStore(folder);
    await store.write('token', 'a test token');
    final file = File('${folder.path}/token');
    expect(file.statSync().modeString(), 'rw-------');
    expect(folder.statSync().modeString(), 'rwx------');
    expect(await FileTokenStore(folder).read('token'), 'a test token', reason: 'the next launch reads it');
    expect(folder.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty, reason: 'written whole, no temporary left');
    await store.delete('token');
    expect(await store.read('token'), isNull);
  }, skip: skip);

  test("the Keychain's token moves into the file once, and leaves the Keychain", () async {
    final keychain = MemoryTokenStore()..values.addAll({'token': 'old token', 'user': '{"id":"u1","username":"kai"}'});
    final store = FileTokenStore(folder, movedFrom: keychain);
    expect(await store.read('token'), 'old token');
    expect(await store.read('user'), contains('kai'));
    expect(keychain.values, isEmpty, reason: 'deleted from the Keychain once moved');

    await store.delete('token'); // Signed out; a token appears in the Keychain again, which the store must not read.
    keychain.values['token'] = 'not asked for';
    expect(await store.read('token'), isNull, reason: 'the Keychain is asked once only: it may ask for your password');
  }, skip: skip);
}
