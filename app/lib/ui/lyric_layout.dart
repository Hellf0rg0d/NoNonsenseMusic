import 'package:flutter/painting.dart';

/// The height of every lyric line at one width, so a long line can wrap instead of being cut and the list can still
/// be centred on the line being sung.
///
/// Each line is measured with a [TextPainter], the engine that draws the [Text] showing it, so the two never disagree
/// (a height measured by another engine clipped Devanagari on the Mac). A list built with these as its item extents
/// stays lazy.
class LyricLayout {
  /// The least height of a line, which a short one keeps, as before wrapping was added.
  static const minExtent = 44.0;

  /// Space above and below a line's text.
  static const gap = 7.0;

  /// Space between a translated line's original, above, and its translation.
  static const aboveGap = 3.0;

  final List<double> extents;
  final List<double> offsets;
  const LyricLayout._(this.extents, this.offsets);

  /// Measures [lines] set in [style] where each may be [width] wide.
  factory LyricLayout.measure(
    List<String> lines, {
    required TextStyle style,
    required double width,
    required TextDirection direction,
    required TextScaler scaler,
    List<String>? above,
    TextStyle? aboveStyle,
  }) {
    final extents = <double>[];
    final offsets = <double>[];
    var at = 0.0;
    final painter = TextPainter(textDirection: direction, textScaler: scaler);
    for (final (i, line) in lines.indexed) {
      painter
        ..text = TextSpan(text: line.isEmpty ? ' ' : line, style: style)
        ..layout(maxWidth: width);
      var h = painter.height + 2 * gap;
      // translated lyrics: the line as sung, small, over its translation (aboveGap between them)
      final over = above != null && i < above.length ? above[i] : '';
      if (over.isNotEmpty) {
        painter
          ..text = TextSpan(text: over, style: aboveStyle ?? style)
          ..layout(maxWidth: width);
        h += painter.height + aboveGap;
      }
      offsets.add(at);
      extents.add(h < minExtent ? minExtent : h);
      at += extents.last;
    }
    painter.dispose();
    return LyricLayout._(extents, offsets);
  }

  /// Where the middle of line [i] is, from the top of the list.
  double centerOf(int i) {
    final k = i.clamp(0, extents.length - 1);
    return offsets[k] + extents[k] / 2;
  }
}
