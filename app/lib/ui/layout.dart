import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Phone windows use bottom navigation rather than the desktop sidebar. This threshold leaves
/// enough room for a readable search field and song rows on compact Android devices.
const phoneWidth = 700.0;

bool isPhone(BuildContext context) =>
    MediaQuery.sizeOf(context).width < phoneWidth;

/// "1 song", "12 songs".
String songCount(int n) => n == 1 ? '1 song' : '$n songs';

/// A touch screen: one tap plays and a long-press opens a song's menu, where a mouse double-clicks and right-clicks.
/// By platform, not width: a narrow window on a computer still has a mouse (a phone needed two taps to play, 13 Oct).
bool get isTouchDevice => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// How tall the floating bottom area is (a phone's messages, player bar and bottom bar), so lists can end above it.
/// The shell measures it and puts it here; nothing above the shell has one.
class BottomArea extends InheritedWidget {
  const BottomArea({super.key, required this.height, required super.child});
  final double height;
  @override
  bool updateShouldNotify(BottomArea old) => old.height != height;
}

/// The space a scrolling list leaves after its last row, so that row is not under the player bar. A phone's floating
/// area is measured (its height changes with the gesture strip, larger text, a message); 120 was too little on a
/// phone and the last song sat under the bar (13 Oct). A computer's bar floats at a known height.
double bottomClearance(BuildContext context, {double extra = 0}) {
  final area = context.dependOnInheritedWidgetOfExactType<BottomArea>()?.height ?? 0;
  return area > 0 ? area + 16 + extra : 120 + extra;
}

/// Reports its child's height after each layout that changes it.
class MeasureHeight extends SingleChildRenderObjectWidget {
  const MeasureHeight({super.key, required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;
  @override
  RenderObject createRenderObject(BuildContext context) => RenderMeasureHeight(onHeight);
  @override
  void updateRenderObject(BuildContext context, RenderMeasureHeight renderObject) => renderObject.onHeight = onHeight;
}

class RenderMeasureHeight extends RenderProxyBox {
  RenderMeasureHeight(this.onHeight);
  ValueChanged<double> onHeight;
  double? _last;
  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h != _last) {
      _last = h;
      WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(h)); // not during layout
    }
  }
}
