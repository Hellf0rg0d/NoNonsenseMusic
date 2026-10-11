import 'package:flutter/widgets.dart';

/// Whether the window is in front: focused and shown.
///
/// UI that advances by itself (the progress tick, lyrics following the song) moves only while this is true, and
/// catches up when the user returns: a visible Flutter window pays about 8 ms of CPU for every frame it draws,
/// even for a single tick, and playback used 1.46% CPU with the window in front against 0.67% behind. Animation
/// that no one sees is wasted work.
final inFront = ValueNotifier<bool>(true);

final AppLifecycleListener _listener = AppLifecycleListener(onStateChange: (s) => inFront.value = s == AppLifecycleState.resumed);

/// Begin observing the app lifecycle and seed [inFront] from the current state. Call once at startup.
void watchInFront() {
  _listener; // referencing the field forces its lazy initialization
  inFront.value = WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
}
