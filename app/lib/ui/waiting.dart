import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

/// Show a still hourglass mark in place of a spinner.
///
/// Flutter's CircularProgressIndicator redraws at the screen's full rate: loading a song for a few seconds
/// consumed about 40% of a CPU core in a Release build. A static icon costs nothing.
class Waiting extends StatelessWidget {
  final double size;
  final String tooltip;
  const Waiting({super.key, this.size = 18, this.tooltip = 'Loading…'});
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Icon(FluentIcons.hourglass_half_24_regular, size: size, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
      );
}
