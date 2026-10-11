import 'dart:async';
import 'dart:io';

import 'package:smtc_windows/smtc_windows.dart';

import 'player.dart';

/// Exposes playback to Windows' System Media Transport Controls (SMTC): the media keys, and the overlay with the
/// song and its cover that appears when the user presses them or changes the volume.
///
/// The player reports song changes and play or pause transitions, never a per-second position, so the overlay carries
/// no running progress. Does nothing on platforms other than Windows.
class MediaControls {
  final Player player;
  SMTCWindows? _smtc;
  StreamSubscription? _buttons;
  String? _shown;
  bool? _playing;

  MediaControls(this.player);

  /// Initialize the SMTC API; a no-op on platforms other than Windows.
  static Future<void> initialize() async {
    if (Platform.isWindows) await SMTCWindows.initialize();
  }

  /// Create the SMTC overlay, route its button presses to the player, and start mirroring the player's state.
  void start() {
    if (!Platform.isWindows) return;
    _smtc = SMTCWindows(
      config: const SMTCConfig(
        playEnabled: true, pauseEnabled: true, nextEnabled: true, prevEnabled: true,
        stopEnabled: false, fastForwardEnabled: false, rewindEnabled: false,
      ),
    );
    _buttons = _smtc!.buttonPressStream.listen((b) {
      switch (b) {
        case PressedButton.play || PressedButton.pause:
          player.togglePlayPause();
        case PressedButton.next:
          player.next();
        case PressedButton.previous:
          player.previous();
        default:
          break;
      }
    });
    player.addListener(_changed);
  }

  void _changed() {
    final smtc = _smtc, t = player.current;
    if (smtc == null) return;
    if (t == null) {
      if (_shown != null) smtc.clearMetadata();
      _shown = null;
      return;
    }
    if (_shown != t.id) {
      _shown = t.id;
      smtc.updateMetadata(MusicMetadata(title: t.title, artist: t.artistLine, album: t.best.album ?? '', albumArtist: t.artistLine, thumbnail: t.image));
    }
    if (_playing != player.isPlaying) {
      _playing = player.isPlaying;
      smtc.setPlaybackStatus(player.isPlaying ? PlaybackStatus.playing : PlaybackStatus.paused);
    }
  }

  /// Stop mirroring the player and release the SMTC overlay.
  void dispose() {
    player.removeListener(_changed);
    _buttons?.cancel();
    _smtc?.dispose();
  }
}
