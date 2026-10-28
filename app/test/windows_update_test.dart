// On Windows CI only (windows.yml sets NN_E2E_NEW_SETUP): an installed app updated in place by the app's own code
// (core/update_check.dart) to a 9.9.9 setup served here and signed with a key made here: read the feed, download, check
// the signature, run the setup silently. The installed version must then be 9.9.9, and the app open again.
// ignore_for_file: avoid_print (what it found goes to the CI log)
@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/update_check.dart';

const uninstallKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6E0B9C1A-4D7F-4C2B-9E3A-5B8D2F1C7A64}_is1';

String? installedVersion() {
  final r = Process.runSync('reg', ['query', uninstallKey, '/v', 'DisplayVersion']);
  return RegExp(r'DisplayVersion\s+REG_SZ\s+(\S+)').firstMatch('${r.stdout}')?.group(1);
}

bool appRunning() => '${Process.runSync('tasklist', ['/FI', 'IMAGENAME eq NoNonsenseMusic.exe']).stdout}'.contains('NoNonsenseMusic.exe');

void main() {
  final setupPath = Platform.environment['NN_E2E_NEW_SETUP'];

  test('the installed app updates itself to 9.9.9 and opens again', () async {
    final before = installedVersion();
    print('installed before: $before, app running: ${appRunning()}');
    expect(before, isNotNull, reason: 'the release setup was installed first');

    final setup = await File(setupPath!).readAsBytes();
    final key = await Ed25519().newKeyPair();
    final signature = base64Encode((await Ed25519().sign(setup, keyPair: key)).bytes);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    server.listen((request) {
      if (request.uri.path == '/update.json') {
        request.response.write(jsonEncode({
          'version': '9.9.9',
          'notes': 'A test update.',
          'files': {
            'NoNonsenseMusic-Setup.exe': {'url': '$base/NoNonsenseMusic-Setup.exe', 'length': setup.length, 'ed_signature': signature},
          },
        }));
      } else {
        request.response.add(setup);
      }
      request.response.close();
    });

    // the test runner is not the installed app, so the file is named here (platformFile offers it to the installed one)
    final update = await checkForUpdate(current: before!, feed: Uri.parse('$base/update.json'), file: 'NoNonsenseMusic-Setup.exe');
    expect(update?.file, isNotNull);
    final folder = Directory.systemTemp.createTempSync('nn-update');
    final downloaded = await downloadUpdate(update!.file!, folder,
        key: base64Encode((await key.extractPublicKey()).bytes));
    var quit = false;
    await installUpdate(downloaded, quit: () => quit = true);
    expect(quit, isTrue, reason: 'the app quits, so the setup can replace it');

    String? after;
    for (var i = 0; i < 120 && after != '9.9.9'; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      after = installedVersion();
    }
    print('installed after: $after');
    expect(after, '9.9.9');
    var reopened = false;
    for (var i = 0; i < 30 && !reopened; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      reopened = appRunning();
    }
    expect(reopened, isTrue, reason: 'a silent setup opens the new version (installer.iss)');
    await server.close(force: true);
  }, skip: setupPath == null ? 'windows.yml runs it, after making the setups' : false, timeout: const Timeout(Duration(minutes: 4)));
}
