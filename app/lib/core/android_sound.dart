import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:shared_preferences/shared_preferences.dart';

/// Android's own equalizer and loudness boost, through just_audio (29 Oct). The equalizer is the phone's: its bands (about
/// five, their frequencies and range set by the phone) are not the Mac's 14. Windows has no counterpart yet. Both
/// effects are made with the player (the pipeline) and are on only when switched on; their bands are known once the first
/// song has loaded, so what is saved is put back then.
class AndroidSound extends ChangeNotifier {
  AndroidSound._();
  static final shared = AndroidSound._();
  static bool get available => Platform.isAndroid;

  final equalizer = ja.AndroidEqualizer();
  final loudness = ja.AndroidLoudnessEnhancer();
  late final pipeline = ja.AudioPipeline(androidAudioEffects: [equalizer, loudness]);

  bool on = false;
  double boost = 0; // dB, 0 (off) to [maxBoost]
  List<double> gains = const []; // dB per band, as the phone numbers them
  ja.AndroidEqualizerParameters? parameters; // null until the first song has loaded

  static const maxBoost = 12.0;

  /// At launch: reads what is saved, then waits for the bands (the first song) and puts it back.
  Future<void> restore() async {
    final p = await SharedPreferences.getInstance();
    on = p.getBool('androidEqOn') ?? false;
    boost = (p.getDouble('androidBoost') ?? 0).clamp(0, maxBoost).toDouble();
    gains = decodeGains(p.getStringList('androidEqGains'));
    await equalizer.setEnabled(on);
    await loudness.setEnabled(boost > 0);
    await loudness.setTargetGain(boost);
    final found = await equalizer.parameters;
    parameters = found;
    for (var i = 0; i < found.bands.length && i < gains.length; i++) {
      await found.bands[i].setGain(clampGain(gains[i], found.minDecibels, found.maxDecibels));
    }
    gains = [for (final b in found.bands) b.gain];
    notifyListeners();
  }

  Future<void> setOn(bool value) async {
    on = value;
    await equalizer.setEnabled(value);
    (await SharedPreferences.getInstance()).setBool('androidEqOn', value);
    notifyListeners();
  }

  Future<void> setBand(int i, double gain) async {
    final found = parameters;
    if (found == null || i < 0 || i >= found.bands.length) return;
    final value = clampGain(gain, found.minDecibels, found.maxDecibels);
    await found.bands[i].setGain(value);
    gains = [for (final b in found.bands) b.gain];
    (await SharedPreferences.getInstance()).setStringList('androidEqGains', encodeGains(gains));
    notifyListeners();
  }

  Future<void> setBoost(double db) async {
    boost = db.clamp(0, maxBoost).toDouble();
    await loudness.setEnabled(boost > 0);
    await loudness.setTargetGain(boost);
    (await SharedPreferences.getInstance()).setDouble('androidBoost', boost);
    notifyListeners();
  }
}

/// A saved list of band gains, as the strings they are stored as; anything unreadable is 0 dB.
List<double> decodeGains(List<String>? saved) => [for (final s in saved ?? const <String>[]) double.tryParse(s) ?? 0];

List<String> encodeGains(List<double> gains) => [for (final g in gains) g.toStringAsFixed(1)];

double clampGain(double gain, double min, double max) => gain.clamp(min, max).toDouble();

/// "60", "230", "910", "3.6k", "14k": a band's centre as it is written under its slider.
String frequencyLabel(double hz) {
  if (hz < 1000) return hz.round().toString();
  final k = (hz / 1000);
  return '${k == k.roundToDouble() ? k.round() : k.toStringAsFixed(1)}k';
}
