import 'dart:convert';

import 'package:http/http.dart' as http;

/// "An update is available", as the Mac app does: once per launch the app asks GitHub for the latest release and
/// compares its tag with its own version. The one request the app makes that does not go to your server; Settings
/// › Check for updates turns it off.
class UpdateInfo {
  const UpdateInfo(this.version, this.page);
  final String version; // "0.3.0"
  final Uri page; // the release's page, where the downloads are
}

final latestRelease = Uri.parse('https://api.github.com/repos/ego004/NoNonsenseMusic/releases/latest');

/// A newer release than [current] that is not [skipped], or null (none, skipped, or GitHub not reachable).
Future<UpdateInfo?> checkForUpdate({required String current, String? skipped, http.Client? client}) async {
  try {
    final r = await (client ?? http.Client())
        .get(latestRelease, headers: {'Accept': 'application/vnd.github+json'}).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final tag = j['tag_name'] as String, page = Uri.parse(j['html_url'] as String);
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    return isNewer(version, current) && version != skipped ? UpdateInfo(version, page) : null;
  } catch (_) {
    return null;
  }
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
