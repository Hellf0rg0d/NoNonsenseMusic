// Lyrics translation with Google's public endpoint: the reply parser on a fixed sample, and the one-request-per-song
// rules with the network answered by a mock. All lyrics are made up.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/translation.dart';
import 'package:nononsense/ui/lyrics_panel.dart';

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

  group('the pane', () {
    Future<void> show(WidgetTester tester, LyricsTranslations t, List<LyricLine> lines) => tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 340, child: TranslatedLyrics(lines: lines, songId: 'song', translations: t)))));

    testWidgets('each line shows with its translation under it, and a gap is left out', (tester) async {
      Api.client = MockClient((_) async => http.Response('[[["Hello\\n","Hola\\n"],["Bye","Adios"]],null,"es"]', 200));
      final t = LyricsTranslations(language: () => 'en');
      final lines = [line('Hola'), line(''), line('Adios')];
      await t.translate('song', lines);
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
      await t.translate('song', lines);
      await show(tester, t, lines);
      expect(find.text("Couldn't translate these lyrics"), findsOneWidget);
    });
  });
}
