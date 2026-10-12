// Tests for the server address: Api joins "$base/$path", so a trailing "/" asked for "//search" and every request failed.
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an address typed with trailing slashes is kept, and used, without them', () async {
    SharedPreferences.setMockInitialValues({});
    final s = Settings();
    await s.load();
    await s.setServer('  https://music.example.com//  ');
    expect(s.server, 'https://music.example.com');
    expect(Api.base, 'https://music.example.com');
    expect((await SharedPreferences.getInstance()).getString('server'), 'https://music.example.com');
  });

  test('an address saved with a trailing slash before this fix is mended when settings load', () async {
    SharedPreferences.setMockInitialValues({'server': 'https://music.example.com/'});
    final s = Settings();
    await s.load();
    expect(s.server, 'https://music.example.com');
    expect(Api.base, 'https://music.example.com');
  });
}
