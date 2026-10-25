import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// In-place updates, as the Mac app's Sparkle does them: once per launch the app reads the latest release's
/// update.json (scripts/make-update-feeds.py), and a newer version is offered with its notes. Update downloads this
/// platform's file, checks its length and its Ed25519 signature against the release key built into the app (a file
/// not signed by it is refused and deleted), then installs it: Windows runs the setup silently, which closes the app
/// and opens the new version; Android hands the APK to its installer. The one request the app makes that does not go
/// to your server; Settings › Check for updates turns it off.
class UpdateInfo {
  const UpdateInfo(this.version, this.notes, this.file, this.page);
  final String version; // "0.4.1"
  final String notes; // what is new, as the release says it (Markdown)
  final UpdateFile? file; // this platform's, or null: then only the page
  final Uri page; // the release's page
}

class UpdateFile {
  const UpdateFile(this.name, this.url, this.length, this.signature);
  final String name;
  final Uri url;
  final int length;
  final List<int> signature; // Ed25519, 64 bytes
}

/// Why an update was not installed, worded to be shown as it is.
class UpdateRefused implements Exception {
  UpdateRefused(this.text);
  final String text;
  @override
  String toString() => text;
}

const _releases = 'https://github.com/ego004/NoNonsenseMusic/releases';
final latestFeed = Uri.parse('$_releases/latest/download/update.json');

/// The release key's public half (Sparkle's generate_keys, account nononsensemusic; the Mac app's SUPublicEDKey).
/// --dart-define=NN_UPDATE_KEY=… replaces it for a test build.
const releaseKey = String.fromEnvironment('NN_UPDATE_KEY', defaultValue: 'RELEASE_KEY_PENDING');

/// This platform's file in a release.
String? get platformFile => Platform.isWindows
    ? 'NoNonsenseMusic-Setup.exe'
    : Platform.isAndroid
        ? 'NoNonsenseMusic-Android.apk'
        : null;

/// A newer release than [current] that is not [skipped], or null (none, skipped, or GitHub not reachable).
Future<UpdateInfo?> checkForUpdate(
    {required String current, String? skipped, http.Client? client, Uri? feed, String? file}) async {
  try {
    final r = await (client ?? http.Client()).get(feed ?? latestFeed).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final version = j['version'] as String;
    if (!isNewer(version, current) || version == skipped) return null;
    final files = j['files'] as Map<String, dynamic>? ?? const {};
    final mine = files[file ?? platformFile] as Map<String, dynamic>?;
    return UpdateInfo(
      version,
      j['notes'] as String? ?? '',
      mine == null
          ? null
          : UpdateFile(file ?? platformFile!, Uri.parse(mine['url'] as String), (mine['length'] as num).toInt(),
              base64Decode(mine['ed_signature'] as String)),
      Uri.parse('$_releases/tag/v$version'),
    );
  } catch (_) {
    return null;
  }
}

/// [file] downloaded into [folder], its length and signature checked against [key] (base64): the path to install, or
/// [UpdateRefused] (the file deleted). [progress] gets the share downloaded, 0 to 1.
Future<File> downloadUpdate(UpdateFile file, Directory folder,
    {String key = releaseKey, http.Client? client, void Function(double)? progress}) async {
  final publicKey = _key(key);
  await folder.create(recursive: true);
  final out = File('${folder.path}${Platform.pathSeparator}${file.name}');
  final c = client ?? http.Client();
  try {
    final response = await c.send(http.Request('GET', file.url)).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw UpdateRefused('The download answered ${response.statusCode}.');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
      bytes.add(chunk);
      if (bytes.length > file.length) break;
      progress?.call(bytes.length / file.length);
    }
    final data = bytes.takeBytes();
    if (data.length != file.length) {
      throw UpdateRefused('The download is not the size the release says (${data.length} of ${file.length} bytes).');
    }
    final valid = await Ed25519().verify(data,
        signature: Signature(file.signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
    if (!valid) throw UpdateRefused('The download is not signed by NoNonsenseMusic’s release key, so it was not installed.');
    await out.writeAsBytes(data, flush: true);
    return out;
  } on UpdateRefused {
    if (await out.exists()) await out.delete();
    rethrow;
  } on TimeoutException {
    throw UpdateRefused('The download stopped answering.');
  } on SocketException catch (e) {
    throw UpdateRefused('The download failed: ${e.message}.');
  } finally {
    if (client == null) c.close();
  }
}

List<int> _key(String base64Key) {
  try {
    final bytes = base64Decode(base64Key);
    if (bytes.length == 32) return bytes;
  } on FormatException {
    // below
  }
  throw UpdateRefused('This build has no release key, so it cannot check an update. Download it from the release page.');
}

/// Installs a checked download. Windows: the setup, silently; it closes this app and opens the new version (installer.iss),
/// so this app quits ([quit]). Android: the system's installer, which asks first (and, the first time, for permission to
/// install from this app). Returns what the user is told, or null when there is nothing to say.
Future<String?> installUpdate(File file, {void Function()? quit}) async {
  if (Platform.isWindows) {
    await Process.start(file.path, ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached);
    (quit ?? () => exit(0))();
    return null;
  }
  if (Platform.isAndroid) {
    final answer = await const MethodChannel('nononsense/update').invokeMethod<String>('install', {'path': file.path});
    return answer == 'permission'
        ? 'Allow NoNonsenseMusic to install apps, then tap Update again.'
        : null;
  }
  return null;
}

/// "0.10.0" is newer than "0.9.1": compared number by number, a missing number counting as 0.
bool isNewer(String a, String b) {
  final x = [for (final p in a.split('.')) int.tryParse(p) ?? 0], y = [for (final p in b.split('.')) int.tryParse(p) ?? 0];
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p > q;
  }
  return false;
}
