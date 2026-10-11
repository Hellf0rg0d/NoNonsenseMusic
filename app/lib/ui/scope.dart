import 'package:flutter/widgets.dart';

import '../core/auth.dart';
import '../core/library.dart';
import '../core/lyrics.dart';
import '../core/player.dart';
import '../core/settings.dart';

/// Supply the app's one player, one library, lyrics, settings and auth to every screen below.
///
/// The objects are built once in `main.dart` and stay the same for the whole session, so no
/// screen builds its own. The macOS app passes the same objects with `.environment`.
class Scope extends InheritedWidget {
  final Player player;
  final Library library;
  final LyricsStore lyrics;
  final Settings settings;
  final Auth auth;
  const Scope({super.key, required this.player, required this.library, required this.lyrics, required this.settings, required this.auth, required super.child});

  /// Return the [Scope] that [c] sits below.
  ///
  /// The lookup throws when the tree above [c] holds no [Scope].
  static Scope of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<Scope>()!;
  @override
  bool updateShouldNotify(Scope old) => false; // fields are final; redraws come from the objects' own listeners
}
