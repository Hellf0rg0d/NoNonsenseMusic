// UI v2 (15 Oct): the redesigned window on a computer: the floating sidebar, the top actions and Home fit every window
// size without an overflow, the search box sits in the middle of the top bar, Ctrl+K opens the command bar, and the
// sidebar opens Library.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/core/social.dart';
import 'package:nononsense/ui/command_bar.dart';
import 'package:nononsense/ui/redesign.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/shell.dart';
import 'package:nononsense/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> window(WidgetTester tester, Size size, {Brightness brightness = Brightness.dark}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final settings = Settings();
  await settings.load();
  final player = Player();
  addTearDown(player.dispose);
  await tester.pumpWidget(Scope(
    player: player,
    library: Library(),
    lyrics: LyricsStore(),
    settings: settings,
    auth: Auth(store: MemoryTokenStore()),
    child: MaterialApp(theme: buildTheme(brightness, null), home: const Shell()),
  ));
  await tester.pump(const Duration(seconds: 1));
}

/// The shell starts the live friends connection: stopped, and its wait before trying again run out, before the test ends.
Future<void> close(WidgetTester tester) async {
  Social.shared.stop();
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  for (final size in [const Size(1000, 700), const Size(1280, 800), const Size(1920, 1009)]) {
    for (final brightness in Brightness.values) {
      testWidgets('the redesigned window fits $size, ${brightness.name}', (tester) async {
        await window(tester, size, brightness: brightness);
        expect(tester.takeException(), isNull);
        expect(find.byType(DesktopSidebar), findsOneWidget);
        expect(find.text('NoNonsenseMusic'), findsOneWidget);
        expect(find.byType(TopActions), findsOneWidget);
        await close(tester);
      });
    }
  }

  for (final size in [const Size(1920, 1009), const Size(1280, 800), const Size(1000, 700)]) {
    testWidgets('the search box is in the middle of the top bar, clear of Jam and the bell, at $size', (tester) async {
      await window(tester, size);
      final row = tester.getRect(find.ancestor(of: find.byType(CommandBar), matching: find.byType(CustomMultiChildLayout)).first);
      final box = tester.getRect(find.byType(CommandBar));
      final actions = tester.getRect(find.byType(TopActions));
      expect(box.right, lessThanOrEqualTo(actions.left - 12));
      expect(box.left, greaterThanOrEqualTo(row.left));
      // in the middle wherever there is room for it to be; a narrow window moves it left, never under Jam
      if (box.width / 2 + actions.width + 12 <= row.width / 2) expect(box.center.dx, moreOrLessEquals(row.center.dx));
      expect(tester.takeException(), isNull);
      await close(tester);
    });
  }

  testWidgets('Ctrl+K puts the keyboard in the command bar; the sidebar opens Library', (tester) async {
    await window(tester, const Size(1280, 800));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('SUGGESTED'), findsOneWidget, reason: 'the command bar opened its list');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.tap(find.text('Library'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Collections'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });
}
