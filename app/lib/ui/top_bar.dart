import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'command_bar.dart';
import 'jam_panel.dart';
import 'layout.dart';
import 'notifications.dart';
import 'redesign.dart';

/// Puts the top bar above [child], the screen.
///
/// On a computer: the search and command box in the middle (20 Oct; it was at the left, where the page's content
/// starts), and Jam with the bell at the right. With no [places] (the Search page, which has its own field) the box is
/// left out. On a phone the bar sits below the status bar with Jam, the bell and Settings (a phone has no sidebar to
/// hold it): one short row, so a screen keeps nearly all its height.
class TopBarFrame extends StatelessWidget {
  final Widget child;
  final CommandPlaces? places;
  final VoidCallback? openSettings;
  const TopBarFrame({super.key, required this.child, this.places, this.openSettings});

  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
    final side = gutter(context);
    return Column(children: [
      SafeArea(
        bottom: false,
        child: phone
            ? SizedBox(
                height: 48,
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  JamButton(),
                  NotificationsButton(),
                  if (openSettings != null)
                    IconButton(tooltip: 'Settings', onPressed: openSettings, icon: const Icon(FluentIcons.settings_24_regular)),
                  const SizedBox(width: 8),
                ]),
              )
            : Padding(
                padding: EdgeInsets.fromLTRB(side, 14, side, 0),
                child: SizedBox(
                  height: 44,
                  child: CustomMultiChildLayout(delegate: _TopRow(), children: [
                    if (places != null) LayoutId(id: _TopRow.box, child: CommandBar(places: places!)),
                    LayoutId(id: _TopRow.actions, child: TopActions(bell: NotificationsButton())),
                  ]),
                ),
              ),
      ),
      Expanded(child: child),
    ]);
  }
}

/// A computer's top row (20 Oct): the search box in the middle of the page's width, Jam with the bell at the right.
/// Where the window is too narrow for the box to stay in the middle, it moves left rather than under them.
class _TopRow extends MultiChildLayoutDelegate {
  static const box = 'box', actions = 'actions';
  static const _widest = 560.0, _gap = 12.0;

  @override
  void performLayout(Size size) {
    final right = layoutChild(actions, BoxConstraints.loose(size));
    positionChild(actions, Offset(size.width - right.width, (size.height - right.height) / 2));
    if (!hasChild(box)) return;
    final room = math.max(0.0, size.width - right.width - _gap); // left of Jam and the bell
    final field = layoutChild(box, BoxConstraints(maxWidth: math.min(_widest, room), maxHeight: size.height));
    final middle = (size.width - field.width) / 2;
    positionChild(box, Offset(math.max(0.0, math.min(middle, room - field.width)), (size.height - field.height) / 2));
  }

  @override
  bool shouldRelayout(_TopRow old) => false;
}
