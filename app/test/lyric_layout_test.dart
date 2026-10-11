// Long lyric lines wrap and are measured by the engine that draws them, in any script. Made-up lines.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/ui/lyric_layout.dart';

void main() {
  const style = TextStyle(fontSize: 18, fontWeight: FontWeight.w700);
  const lines = [
    'Short',
    'A very long line of made-up lyrics that cannot possibly fit on one row of a narrow panel',
    'तुम ही हो आशिकी में तेरी सब कुछ तू ही है यह एक बहुत लंबी बनाई हुई पंक्ति है जो एक पंक्ति में नहीं आएगी',
    '',
  ];

  test('a long line is taller than a short one; a gap keeps the least height; offsets add up', () {
    final l = LyricLayout.measure(lines, style: style, width: 300, direction: TextDirection.ltr, scaler: TextScaler.noScaling);
    expect(l.extents[0], LyricLayout.minExtent);
    expect(l.extents[1], greaterThan(l.extents[0] * 1.5));
    expect(l.extents[2], greaterThan(l.extents[0] * 1.5));
    expect(l.extents[3], LyricLayout.minExtent);
    expect(l.offsets, [0, l.extents[0], l.extents[0] + l.extents[1], l.extents[0] + l.extents[1] + l.extents[2]]);
    expect(l.centerOf(1), l.offsets[1] + l.extents[1] / 2);
  });

  test('a narrower panel and a larger text size make lines taller', () {
    double total(double width, TextScaler s) =>
        LyricLayout.measure(lines, style: style, width: width, direction: TextDirection.ltr, scaler: s).extents.fold(0, (a, b) => a + b);
    expect(total(200, TextScaler.noScaling), greaterThan(total(300, TextScaler.noScaling)));
    expect(total(300, const TextScaler.linear(1.4)), greaterThan(total(300, TextScaler.noScaling)));
  });

  testWidgets('each measured extent holds the drawn text whole: no clipping, no ellipsis, in Latin and Devanagari', (tester) async {
    const width = 300.0;
    final l = LyricLayout.measure(lines, style: style, width: width, direction: TextDirection.ltr, scaler: TextScaler.noScaling);
    for (final (i, text) in lines.indexed.where((e) => e.$2.isNotEmpty)) {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: Align(alignment: Alignment.topLeft, child: SizedBox(width: width, child: Text(text, style: style))),
        ),
      ));
      final drawn = tester.getSize(find.byType(Text)).height;
      expect(drawn + 2 * LyricLayout.gap, lessThanOrEqualTo(l.extents[i] + 0.01), reason: 'line $i fits its extent');
      expect(tester.widget<Text>(find.byType(Text)).overflow, isNot(TextOverflow.ellipsis));
    }
  });
}
