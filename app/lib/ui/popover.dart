import 'package:flutter/material.dart';

import 'layout.dart';

/// Shows [builder]'s panel from the control [anchor] belongs to: a bottom sheet on a phone, a popover under the
/// control on a wide window.
///
/// The panel closes on a tap outside it, and its content closes it with `Navigator.pop`. Returns when it closes.
Future<void> showPanel(BuildContext anchor, {required WidgetBuilder builder, double width = 340}) {
  if (isPhone(anchor)) {
    return showModalBottomSheet<void>(
      context: anchor,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => Padding(
        // the keyboard lifts the sheet, so a field in it stays in view
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: builder(context),
        ),
      ),
    );
  }
  final box = anchor.findRenderObject()! as RenderBox;
  final from = box.localToGlobal(Offset.zero);
  final screen = MediaQuery.sizeOf(anchor);
  final top = from.dy + box.size.height + 4;
  final right = (screen.width - from.dx - box.size.width).clamp(8.0, screen.width);
  final theme = Theme.of(anchor);
  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(anchor).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => Stack(children: [
      Positioned(
        top: top,
        right: right,
        width: width,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: (screen.height - top - 24).clamp(200.0, 640.0)),
          child: Material(
            color: theme.popupMenuTheme.color ?? theme.colorScheme.surfaceContainerHighest,
            elevation: 8,
            shadowColor: Colors.black,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: builder(context),
          ),
        ),
      ),
    ]),
  );
}
