// The Storage section and the Download button build without overflow on a phone and a desktop window.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/audio_cache.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/download_store.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/download_button.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/storage_settings.dart';
import 'package:nononsense/ui/theme.dart';

void main() {
  for (final (w, h) in [(360.0, 740.0), (390.0, 844.0), (1280.0, 800.0)]) {
    testWidgets('Storage settings and Download build at ${w.toInt()}x${h.toInt()}', (tester) async {
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dir = Directory.systemTemp.createTempSync('storage_layout');
      addTearDown(() => dir.deleteSync(recursive: true));
      final tracks = [
        for (var i = 0; i < 3; i++)
          Track(Listing(source: 'jiosaavn', id: '$i', title: 'Song $i', artists: const ['Alex'], duration: 200), const [],
              choosingVersion: false),
      ];
      final store = DownloadStore(cache: AudioCache(dir));
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light, null),
        home: Scope(
          player: Player(), library: Library(), lyrics: LyricsStore(), settings: Settings(), auth: Auth(store: MemoryTokenStore()),
          child: Scaffold(
            body: ListView(padding: const EdgeInsets.all(32), children: [
              StorageSettings(cache: AudioCache(dir), downloads: store),
              Wrap(spacing: 10, children: [DownloadAllButton(tracks: tracks, store: store)]),
            ]),
          ),
        ),
      ));
      expect(find.text('Keep songs on this device'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
    });
  }
}
