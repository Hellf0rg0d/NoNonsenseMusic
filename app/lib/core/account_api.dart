import 'dart:convert';

import 'api.dart';

/// The account calls that need their own error handling: recovery codes and the password reset.
///
/// They sit apart from [Api] because a 401 here does not mean the session ended. It means the typed password or
/// recovery code was wrong, and [Api.sendJson] would sign the user out for it.
class AccountApi {
  /// Sets a new password with one recovery code and returns the new session. The code is used up and every other
  /// device is signed out. Sent without a token: this call makes one.
  static Future<(String token, AuthUser user)> recover(
      String username, String code, String newPassword, String device) async {
    final r = await Api.client
        .post(Uri.parse('${Api.base}/auth/recover'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'username': username, 'code': code, 'new_password': newPassword, 'device_name': device}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200 && r.statusCode != 201) throw ApiError(r.statusCode, Api.detailOf(r.body));
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return (j['token'] as String, AuthUser.fromJson(j['user'] as Map<String, dynamic>));
  }

  /// How many of the account's ten recovery codes are unused.
  static Future<int> codesLeft() async => ((await Api.getJson('auth/recovery-codes')) as Map)['left'] as int;

  /// Replaces the account's recovery codes with a new set of ten. The password is asked again so an unattended
  /// session cannot replace them. A 401 is a wrong password, never an ended session, so the answer is read here
  /// and [Api.onSignedOut] is not told.
  static Future<List<String>> newCodes(String password) async {
    final token = Api.token;
    final r = await Api.client
        .post(Uri.parse('${Api.base}/auth/recovery-codes'),
            headers: {'content-type': 'application/json', if (token != null) 'authorization': 'Bearer $token'},
            body: jsonEncode({'password': password}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401) throw ApiError(401, 'Wrong password.');
    if (r.statusCode != 200 && r.statusCode != 201) throw ApiError(r.statusCode, Api.detailOf(r.body));
    return [...((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['codes'] as List).cast<String>()];
  }
}
