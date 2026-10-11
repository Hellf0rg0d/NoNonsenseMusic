import 'package:flutter/material.dart';

import 'jam_panel.dart';
import 'layout.dart';
import 'notifications.dart';

/// Puts the top bar above [child], the screen: the jam button and the notifications bell at the right.
///
/// On a phone the bar sits below the status bar. It is one short row, so a screen keeps nearly all its height.
class TopBarFrame extends StatelessWidget {
  final Widget child;
  const TopBarFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
    return Column(children: [
      SafeArea(
        bottom: false,
        child: SizedBox(
          height: phone ? 48 : 44,
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            JamButton(),
            NotificationsButton(),
            SizedBox(width: phone ? 8 : 20),
          ]),
        ),
      ),
      Expanded(child: child),
    ]);
  }
}
