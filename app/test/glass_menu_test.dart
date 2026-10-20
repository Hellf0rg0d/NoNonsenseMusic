// The song menu's glass (glass_menu.dart): the choice comes back, a click outside answers null, a disabled line does
// nothing, it opens away from the window's edges, nothing fades its glass from outside while it comes in, and the glass
// hides what is behind it on a see-through window.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/ui/concept.dart';
import 'package:nononsense/ui/glass_menu.dart';

const entries = [
  GlassMenuEntry('like', 'Remove from Liked'),
  GlassMenuEntry('playlist', 'Add to Playlist…'),
  GlassMenuEntry<String>.divider(),
  GlassMenuEntry<String>.disabled('Downloading…'),
  GlassMenuEntry('artist', 'Go to Artist'),
];

void main() {
  late String? chosen;
  late bool answered;

  Future<void> open(WidgetTester tester, Offset at) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    answered = false;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: Builder(builder: (context) => Center(
        child: TextButton(
          onPressed: () async {
            chosen = await showGlassMenu<String>(context, at, entries);
            answered = true;
          },
          child: const Text('open'),
        ),
      ))),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
  }

  testWidgets('a choice comes back; the menu is on glass', (tester) async {
    await open(tester, const Offset(100, 100));
    await tester.pumpAndSettle();
    expect(find.ancestor(of: find.text('Go to Artist'), matching: find.byType(GlassCard)), findsOneWidget);
    expect(tester.getTopLeft(find.byType(GlassCard)), const Offset(100, 100));       // opens at the click
    await tester.tap(find.text('Go to Artist'));
    await tester.pumpAndSettle();
    expect((answered, chosen), (true, 'artist'));
  });

  testWidgets('a disabled line does nothing; a click outside closes with nothing chosen', (tester) async {
    await open(tester, const Offset(100, 100));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Downloading…'));
    await tester.pumpAndSettle();
    expect(find.text('Go to Artist'), findsOneWidget);
    await tester.tapAt(const Offset(900, 600));
    await tester.pumpAndSettle();
    expect((answered, chosen, find.text('Go to Artist').evaluate().isEmpty), (true, null, true));
  });

  testWidgets('by the bottom right corner it opens up and to the left', (tester) async {
    await open(tester, const Offset(1150, 760));
    await tester.pumpAndSettle();
    final menu = tester.getRect(find.byType(GlassCard));
    expect((menu.right, menu.bottom), (1150, 760));
  });

  moreGlass();

  testWidgets('while it comes in, nothing fades its glass from outside', (tester) async {
    await open(tester, const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 80));
    final fading = find.byWidgetPredicate((w) => (w is Opacity && w.opacity < 1) || w is FadeTransition);
    expect(find.ancestor(of: find.byType(BackdropFilter), matching: fading), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('on a see-through window the glass hides the lines behind it', (tester) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // a page's text over nothing, as on Mica: white lines, no background
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Stack(children: [
        for (var y = 10.0; y < 290; y += 20)
          Positioned(left: 10, top: y, width: 380, height: 8, child: const ColoredBox(color: Colors.white)),
        const Positioned(left: 100, top: 60, width: 200, height: 180, child: GlassCard(child: SizedBox.expand())),
      ]),
    ));
    final view = tester.binding.renderViews.first;
    // ignore: invalid_use_of_protected_member
    final layer = view.layer! as OffsetLayer;
    final pixels = (await tester.runAsync(() async {
      final image = await layer.toImage(Offset.zero & view.size);
      return image.toByteData(format: ui.ImageByteFormat.rawRgba);
    }))!;
    // down the middle of the glass, away from its edges: lines drawn sharp under it alternate bright and dark (44 and 81
    // with the blur drawn over them; 42 to 46 with it in their place)
    final light = [for (var y = 90; y < 210; y++) pixels.getUint8((y * 400 + 200) * 4)];
    expect(light.reduce(math.max) - light.reduce(math.min), lessThan(12), reason: 'the lines behind show through the glass');
  });
}

/// The copy menu's lines (a tick on the playing copy, a second line of detail), and the glass dialog.
void moreGlass() {
  testWidgets('a line can carry a tick and a second line', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () => showGlassMenu<String>(context, const Offset(40, 40), const [
        GlassMenuEntry('a', 'JioSaavn · AAC 320 kbps', detail: 'Drake · 3:57 · Explicit', checked: true),
        GlassMenuEntry('b', 'YouTube Music · AAC 128 kbps', detail: 'Drake · 3:58', checked: false),
      ]),
      child: const Text('open'),
    )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Drake · 3:57 · Explicit'), findsOneWidget);
    expect(find.byIcon(FluentIcons.checkmark_20_regular), findsOneWidget);       // on the playing copy only
    final tick = tester.getCenter(find.byIcon(FluentIcons.checkmark_20_regular)).dy;
    expect((tick - tester.getCenter(find.text('JioSaavn · AAC 320 kbps')).dy).abs(), lessThan(20));
  });

  for (final dismissible in [true, false]) {
    testWidgets('a glass dialog comes in on glass${dismissible ? '' : ', and stays when it must'}', (tester) async {
      String? answer = 'unset';
      await tester.pumpWidget(MaterialApp(theme: ThemeData(brightness: Brightness.dark), home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () async => answer = await showGlassDialog<String>(
          context: context,
          barrierDismissible: dismissible,
          builder: (c) => GlassDialog(
            title: const Text('Delete “Road trip”?'),
            content: const Text('Its songs stay in your library.'),
            actions: [TextButton(onPressed: () => Navigator.pop(c, 'delete'), child: const Text('Delete'))],
          ),
        ),
        child: const Text('open'),
      )))));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));                  // part way in
      final fading = find.byWidgetPredicate((w) => (w is Opacity && w.opacity < 1) || w is FadeTransition);
      expect(find.ancestor(of: find.byType(BackdropFilter), matching: fading), findsNothing);
      await tester.pumpAndSettle();
      expect(find.ancestor(of: find.text('Its songs stay in your library.'), matching: find.byType(GlassCard)), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));                               // outside
      await tester.pumpAndSettle();
      expect(find.text('Delete').evaluate().isEmpty, dismissible);
      if (!dismissible) {
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(answer, 'delete');
      }
    });
  }
}
