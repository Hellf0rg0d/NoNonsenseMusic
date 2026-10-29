import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/android_sound.dart';

void main() {
  test('saved gains come back as numbers, and a bad one is 0 dB', () {
    expect(decodeGains(['1.5', '-3.0', 'x', '']), [1.5, -3.0, 0, 0]);
    expect(decodeGains(null), isEmpty);
    expect(decodeGains(encodeGains([4.5, -12.0, 0])), [4.5, -12.0, 0]);
  });

  test('a gain stays inside the phone\'s range', () {
    expect(clampGain(20, -15, 15), 15);
    expect(clampGain(-20, -15, 15), -15);
    expect(clampGain(3.5, -15, 15), 3.5);
  });

  test('a band is written as its centre: 60, 910, 3.6k, 14k', () {
    expect(frequencyLabel(60000 / 1000), '60');
    expect(frequencyLabel(910), '910');
    expect(frequencyLabel(3600), '3.6k');
    expect(frequencyLabel(14000), '14k');
  });
}
