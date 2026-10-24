// Lyrics translation with Google's public endpoint: the reply parser on a fixed sample, and the one-request-per-song
// rules with the network answered by a mock. All lyrics are made up.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/core/translation.dart';
import 'package:nononsense/ui/lyrics_panel.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The shape of a real reply (translate_a/single?client=gtx&dt=t) for three Spanish lines, one of them blank-padded:
/// chunks of [translated, original, ...] that keep the line breaks, then the detected language at element 2.
const sampleReply = '[[["Hello how are you?\\n","Hola, ¿cómo estás?\\n",null,null,10],'
    '["I love you very much\\n","Yo te quiero mucho\\n",null,null,3],'
    '["Tonight we dance","Esta noche bailamos",null,null,3]],null,"es",null,null,null,1,[]]';

LyricLine line(String text, {String? translation}) => LyricLine(null, text, translation: translation);

void main() {
  tearDown(() => Api.client = http.Client());

  group('the reply', () {
    test('joined translated parts, split into one line per input line, with the detected language', () {
      final reply = TranslateReply.parse(sampleReply);
      expect(reply.language, 'es');
      expect(reply.splitInto(3), ['Hello how are you?', 'I love you very much', 'Tonight we dance']);
    });

    test('a different number of lines is no answer: a line under the wrong original would mislead', () {
      expect(TranslateReply.parse(sampleReply).splitInto(4), isNull);
      expect(TranslateReply.parse(sampleReply).splitInto(2), isNull);
    });

    test('a changed shape is an error, not wrong text', () {
      expect(() => TranslateReply.parse('{"error": "gone"}'), throwsFormatException);
      expect(() => TranslateReply.parse('[]'), throwsFormatException);
      expect(() => TranslateReply.parse('[[null]]'), throwsFormatException);
    });

    test('the detected language matches the target by its main code', () {
      expect(LyricsTranslations.sameLanguage('en', 'en'), isTrue);
      expect(LyricsTranslations.sameLanguage('zh-CN', 'zh-TW'), isTrue);
      expect(LyricsTranslations.sameLanguage('iw', 'he'), isTrue);
      expect(LyricsTranslations.sameLanguage('es', 'en'), isFalse);
      expect(LyricsTranslations.sameLanguage(null, 'en'), isFalse);
    });
  });

  group('asking', () {
    late List<http.BaseRequest> asked;
    void answer(http.Response Function(http.Request) with_) {
      asked = [];
      Api.client = MockClient((r) async {
        asked.add(r);
        return with_(r);
      });
    }

    http.Response ok(String body) => http.Response.bytes(utf8.encode(body), 200);

    // Google's reply asked with dt=t and dt=rm (24 Oct, made-up lines): the translation's chunks, then [null, null,
    // romanized translation, romanized original]
    const hinglishReply = '[[["हर रात जब शहर सोता है\\n","every night when the city sleeps\\n",null,null],'
        '["मैं अकेला चलता हूँ","I walk alone",null,null],'
        '[null,null,"har raat jab shahar sota hai\\nmain akela chalta hun"]],null,"en"]';

    test('Hinglish: Google is asked for Hindi in Latin letters, and those lines show', () async {
      answer((_) => ok(hinglishReply));
      final t = LyricsTranslations(language: () => LyricsTranslations.hinglish);
      await t.translate('song', [line('every night when the city sleeps'), line(''), line('I walk alone')]);
      final url = asked.single.url;
      expect(url.queryParameters['tl'], 'hi');
      expect(url.queryParametersAll['dt'], ['t', 'rm']);
      expect(t.linesOf('song'), ['har raat jab shahar sota hai', '', 'main akela chalta hun']);
    });

    test('Hinglish: Hindi lyrics in Devanagari are romanized; Hindi already in Latin letters is already Hinglish', () async {
      answer((_) => ok('[[["हर रात","हर रात",null,null],[null,null,"har raat","har raat"]],null,"hi"]'));
      final t = LyricsTranslations(language: () => LyricsTranslations.hinglish);
      await t.translate('devanagari', [line('हर रात')]);
      expect(t.linesOf('devanagari'), ['har raat']);
      expect(t.inReadersLanguage('devanagari'), isFalse);
      answer((_) => ok('[[["har raat","har raat",null,null],[null,null,"har raat","har raat"]],null,"hi"]'));
      await t.translate('latin', [line('har raat')]);
      expect(t.inReadersLanguage('latin'), isTrue);
    });

    test('Hinglish never takes the uploader\'s translation: in Latin letters, it is mostly English', () {
      expect(LyricsTranslations.providedTranslations([line('हर रात', translation: 'every night')], LyricsTranslations.hinglish), isNull);
    });

    test('one request for the whole song: every non-empty line, joined by line breaks, to the device language', () async {
      answer((_) => ok(sampleReply));
      final t = LyricsTranslations(language: () => 'en');
      final lines = [line('Hola, ¿cómo estás?'), line(''), line('Yo te quiero mucho'), line('Esta noche bailamos')];
      await t.translate('song', lines);
      expect(asked, hasLength(1));
      final url = asked.single.url;
      expect((url.host, url.path), ('translate.googleapis.com', '/translate_a/single'));
      expect(url.queryParameters, {'client': 'gtx', 'sl': 'auto', 'tl': 'en', 'dt': 't', 'q': 'Hola, ¿cómo estás?\nYo te quiero mucho\nEsta noche bailamos'});
      expect(t.linesOf('song'), ['Hello how are you?', '', 'I love you very much', 'Tonight we dance'], reason: 'the gap stays a gap');
    });

    test('a song is never asked about twice, whether it was translated or not', () async {
      answer((_) => ok(sampleReply));
      final t = LyricsTranslations(language: () => 'en');
      final lines = [line('a'), line('b'), line('c')];
      await t.translate('song', lines);
      await t.translate('song', lines);
      expect(asked, hasLength(1));
    });

    test('lyrics already in the reader\'s language say so and show nothing translated', () async {
      answer((_) => ok('[[["Hello\\n","Hello\\n"],["there","there"]],null,"en"]'));
      final t = LyricsTranslations(language: () => 'en');
      await t.translate('song', [line('Hello'), line('there')]);
      expect((t.inReadersLanguage('song'), t.linesOf('song')), (true, null));
      await t.translate('song', [line('Hello'), line('there')]);
      expect(asked, hasLength(1));
    });

    test('the uploader\'s own translations are used, without a request, when they are in the reader\'s script', () async {
      answer((_) => ok(sampleReply));
      final t = LyricsTranslations(language: () => 'en');
      await t.translate('song', [line('Hola', translation: 'Hello'), line('Adiós', translation: 'Goodbye')]);
      expect(asked, isEmpty);
      expect(t.linesOf('song'), ['Hello', 'Goodbye']);
    });

    test('uploader translations in another script are not trusted: the song is asked about', () async {
      answer((_) => ok(sampleReply));
      final t = LyricsTranslations(language: () => 'en');
      await t.translate('song', [line('a', translation: 'नमस्ते'), line('b', translation: 'अलविदा'), line('c')]);
      expect(asked, hasLength(1));
    });

    test('Devanagari lyrics are told apart from a Hindi reader\'s translations by script', () {
      expect(LyricsTranslations.inScript('तुम ही हो', 'hi'), isTrue);
      expect(LyricsTranslations.inScript('you are the one', 'hi'), isFalse);
      expect(LyricsTranslations.inScript('you are the one', 'en'), isTrue);
    });

    test('a long song goes in a form body instead of the address', () async {
      answer((_) => ok(sampleReply));
      final t = LyricsTranslations(language: () => 'en');
      final long = [for (var i = 0; i < 3; i++) line('तुम ही हो आशिकी में तेरी सब कुछ तू ही है ' * 12)];
      await t.translate('song', long);
      final request = asked.single as http.Request;
      expect(request.method, 'POST');
      expect(request.url.queryParameters.containsKey('q'), isFalse);
      expect(Uri.splitQueryString(request.body)['q'], long.map((l) => l.text.trim()).join('\n'));
    });

    test('a failure says so, is kept, and is asked again only on request', () async {
      answer((_) => http.Response('', 503));
      final t = LyricsTranslations(language: () => 'en');
      await t.translate('song', [line('a'), line('b')]);
      expect((t.failed('song'), t.linesOf('song')), (true, null));
      await t.translate('song', [line('a'), line('b')]);
      expect(asked, hasLength(1));
      t.retry('song');
      answer((_) => ok('[[["x\\n","a\\n"],["y","b"]],null,"fr"]'));
      await t.translate('song', [line('a'), line('b')]);
      expect(t.linesOf('song'), ['x', 'y']);
    });
  });

  group('the language chosen (Settings › Lyrics › Translate into, #19)', () {
    late List<String> asked; // the language each request asked for
    /// Made-up Spanish lyrics (the server's answer too), translated into Hindi or English by the language asked for;
    /// [from] is the language Google detects.
    void answerByLanguage({String from = 'es', int status = 200}) {
      asked = [];
      Api.client = MockClient((r) async {
        if (r.url.path.endsWith('/lyrics')) {
          return http.Response.bytes(utf8.encode(jsonEncode({'lyrics_source': 'lrclib', 'synced': false, 'lines': [{'text': 'Hola'}, {'text': 'Adiós'}]})), 200,
              headers: {'content-type': 'application/json'});
        }
        final tl = r.url.queryParameters['tl']!;
        asked.add(tl);
        final (a, b) = tl == 'hi' ? ('नमस्ते', 'अलविदा') : ('Hello', 'Goodbye');
        return http.Response.bytes(utf8.encode('[[["$a\\n","Hola\\n"],["$b","Adiós"]],null,"$from"]'), status);
      });
    }

    final spanish = [line('Hola'), line('Adiós')];
    tearDown(() => LyricsStore.translateInto = '');

    test('a song translated is translated again in another language, and each answer is kept for its language', () async {
      answerByLanguage();
      var into = 'en';
      final t = LyricsTranslations(language: () => into);
      await t.translate('song', spanish);
      expect(t.linesOf('song'), ['Hello', 'Goodbye']);
      into = 'hi';
      expect(t.linesOf('song'), isNull, reason: 'the English answer is not the Hindi one');
      await t.translate('song', spanish);
      expect(t.linesOf('song'), ['नमस्ते', 'अलविदा']);
      into = 'en';
      expect(t.linesOf('song'), ['Hello', 'Goodbye']);
      await t.translate('song', spanish);
      expect(asked, ['en', 'hi'], reason: 'one request per song and language: English again is not asked for');
    });

    test('"already in your language" and a failure each hold for their own language', () async {
      answerByLanguage(from: 'en');
      var into = 'en';
      final t = LyricsTranslations(language: () => into);
      await t.translate('song', spanish);
      expect(t.inReadersLanguage('song'), isTrue);
      into = 'hi';
      expect(t.inReadersLanguage('song'), isFalse);
      answerByLanguage(status: 503);
      await t.translate('song', spanish);
      expect(t.failed('song'), isTrue);
      into = 'es';
      expect(t.failed('song'), isFalse, reason: 'Hindi failed, Spanish has not been asked');
      into = 'hi';
      t.retry('song');
      answerByLanguage();
      await t.translate('song', spanish);
      expect(t.linesOf('song'), ['नमस्ते', 'अलविदा']);
    });

    test('the uploader\'s translations are used only when they are in the chosen language\'s script', () async {
      answerByLanguage();
      var into = 'en';
      final t = LyricsTranslations(language: () => into);
      final inEnglish = [line('Hola', translation: 'Hi there'), line('Adiós', translation: 'Bye now')];
      await t.translate('song', inEnglish);
      expect(t.linesOf('song'), ['Hi there', 'Bye now']);
      expect(asked, isEmpty);
      into = 'hi';
      await t.translate('song', inEnglish);
      expect(asked, ['hi'], reason: 'English is not a Hindi reader\'s: Google is asked');
      expect(t.linesOf('song'), ['नमस्ते', 'अलविदा']);
      final inHindi = [line('Hola', translation: 'नमस्ते दोस्त'), line('Adiós', translation: 'फिर मिलेंगे')];
      await t.translate('other', inHindi);
      expect(t.linesOf('other'), ['नमस्ते दोस्त', 'फिर मिलेंगे']);
      expect(asked, ['hi'], reason: 'in Devanagari: used as they are, no request');
    });

    test('the languages offered: each by its own name, in the order of those names, each told apart by its script', () {
      final names = LyricsTranslations.languages.values.toList();
      expect(names, [...names]..sort());
      for (final MapEntry(key: code, value: name) in LyricsTranslations.languages.entries) {
        expect(LyricsTranslations.inScript(name, code), isTrue, reason: '$name ($code) in its own script');
      }
    });

    test('the setting: the device\'s language by default; a language chosen is kept, and the lyrics are asked in it', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = Settings();
      await settings.load();
      expect(settings.translateInto, '');
      final store = LyricsStore();
      answerByLanguage();
      await store.translations.translate('song', spanish);
      expect(asked, [LyricsTranslations.deviceLanguage()]);
      await settings.setTranslateInto('hi');
      await store.translations.translate('song', spanish);
      expect(asked.last, 'hi');
      expect(store.translations.linesOf('song'), ['नमस्ते', 'अलविदा']);
      final next = Settings(); // the next launch
      await next.load();
      expect(next.translateInto, 'hi');
      await next.setTranslateInto('');
      expect(store.translations.linesOf('song'), ['Hello', 'Goodbye'], reason: 'the device\'s language again, as first answered');
      expect(asked, hasLength(2));
    });

    test('a saved language no longer offered is the device\'s again', () async {
      SharedPreferences.setMockInitialValues({'translateInto': 'tlh'});
      final settings = Settings();
      await settings.load();
      expect((settings.translateInto, LyricsStore.translateInto), ('', ''));
    });

    testWidgets('Settings › Lyrics › Translate into: System language first, then the languages; a choice is applied', (tester) async {
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Api.client = MockClient((_) async => http.Response('{}', 200));
      SharedPreferences.setMockInitialValues({});
      final settings = Settings();
      await settings.load();
      await tester.pumpWidget(Scope(
        player: Player(),
        library: Library(),
        lyrics: LyricsStore(),
        settings: settings,
        auth: Auth(store: MemoryTokenStore()),
        child: const MaterialApp(home: Scaffold(body: SettingsScreen())),
      ));
      await tester.pump();
      final row = find.ancestor(of: find.text('Translate into'), matching: find.byType(ListTile));
      await tester.scrollUntilVisible(row, 300, scrollable: find.byType(Scrollable).first);
      final menu = find.descendant(of: row, matching: find.byType(DropdownButton<String>));
      // the row's top showing is not enough: on Windows (a Window section above) the menu sat 18 px under the screen
      await tester.ensureVisible(menu);
      await tester.pumpAndSettle();
      expect(tester.widget<DropdownButton<String>>(menu).items!.map((i) => i.value),
          ['', ...LyricsTranslations.languages.keys]);
      expect(find.descendant(of: row, matching: find.text('System language')), findsOneWidget);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('हिन्दी').last);
      await tester.pumpAndSettle();
      expect((settings.translateInto, LyricsStore.translateInto), ('hi', 'hi'));
      expect(find.descendant(of: row, matching: find.text('हिन्दी')), findsOneWidget);
    });

    testWidgets('lyrics showing translated follow the setting: translated again on a change, the first answer kept', (tester) async {
      SharedPreferences.setMockInitialValues({'lyricsTranslated': true, 'translateInto': 'en'});
      final settings = Settings();
      await settings.load();
      answerByLanguage();
      final song = Track(const Listing(source: 'jiosaavn', id: 'made-up', title: 'Made-Up Song', artists: ['Kai'], duration: 200), const []);
      final player = Player();
      addTearDown(player.dispose);
      player.queue.load([song], 0, shuffled: false);
      player.currentId.value = song.id;
      await tester.pumpWidget(Scope(
        player: player,
        library: Library(),
        lyrics: LyricsStore(),
        settings: settings,
        auth: Auth(store: MemoryTokenStore()),
        child: const MaterialApp(home: Scaffold(body: LyricsPanel())),
      ));
      Future<void> settle() async {
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
        }
      }

      await settle();
      expect(find.text('Hello'), findsOneWidget);
      await settings.setTranslateInto('hi');
      await settle();
      expect(find.text('नमस्ते'), findsOneWidget);
      expect(find.text('Hello'), findsNothing);
      await settings.setTranslateInto('en');
      await settle();
      expect(find.text('Hello'), findsOneWidget);
      expect(asked, ['en', 'hi'], reason: 'English came from the first answer');
    });
  });

  group('the pane', () {
    final track = Track(const Listing(source: 'jiosaavn', id: 'song', title: 'Made-Up Song', artists: ['Kai'], duration: 200), const []);
    Future<void> show(WidgetTester tester, LyricsTranslations t, List<LyricLine> lines) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(width: 340, child: TranslatedLyrics(lyrics: Lyrics(null, false, lines), track: track, translations: t)))));

    testWidgets('timed lyrics stay timed once translated: each line as sung, small, over its translation', (tester) async {
      Api.client = MockClient((_) async => http.Response('[[["Hello\\n","Hola\\n"],["Bye","Adios"]],null,"es"]', 200));
      final t = LyricsTranslations(language: () => 'en');
      final lines = [LyricLine(0, 'Hola'), LyricLine(2000, ''), LyricLine(4000, 'Adios')];
      await t.translate(track.id, lines);
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
        child: MaterialApp(
            home: Scaffold(
                body: SizedBox(width: 340, height: 600,
                    child: TranslatedLyrics(lyrics: Lyrics(null, true, lines), track: track, translations: t)))),
      ));
      await tester.pump();
      expect(find.byType(ListView), findsOneWidget);
      // the timed list (one row per line, gaps included), not the still one: each translation under its line
      expect(find.text('Hola'), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Hello')).dy, greaterThan(tester.getTopLeft(find.text('Hola')).dy));
      expect(tester.getSize(find.text('Hola')).height, lessThan(tester.getSize(find.text('Hello')).height));
      expect(find.text('♪').evaluate().length + find.text('').evaluate().length, greaterThan(0), reason: 'the gap keeps its row');
    });

    testWidgets('each line shows with its translation under it, and a gap is left out', (tester) async {
      Api.client = MockClient((_) async => http.Response('[[["Hello\\n","Hola\\n"],["Bye","Adios"]],null,"es"]', 200));
      final t = LyricsTranslations(language: () => 'en');
      final lines = [line('Hola'), line(''), line('Adios')];
      await t.translate(track.id, lines);
      await show(tester, t, lines);
      expect(find.text('Hola'), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('Adios'), findsOneWidget);
      expect(find.text('Bye'), findsOneWidget);
    });

    testWidgets('a failure says "Couldn\'t translate these lyrics"', (tester) async {
      Api.client = MockClient((_) async => http.Response('', 500));
      final t = LyricsTranslations(language: () => 'en');
      final lines = [line('Hola')];
      await t.translate(track.id, lines);
      await show(tester, t, lines);
      expect(find.text("Couldn't translate these lyrics"), findsOneWidget);
    });
  });
}
