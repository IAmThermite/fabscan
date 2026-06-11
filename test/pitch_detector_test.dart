import 'dart:typed_data';

import 'package:fabscan/src/vision/pitch_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a 100x100 RGB buffer whose Y 0..10 band (the default sample window)
/// is filled with [color] and the rest is mid-grey (skipped by the saturation
/// gate). Lets each test set the pitch strip in isolation.
Uint8List buildCard(List<int> color) {
  const w = 100, h = 100;
  final out = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    final inStrip = y < 10;
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 3;
      if (inStrip) {
        out[i] = color[0];
        out[i + 1] = color[1];
        out[i + 2] = color[2];
      } else {
        out[i] = 128;
        out[i + 1] = 128;
        out[i + 2] = 128;
      }
    }
  }
  return out;
}

void main() {
  const detector = PitchDetector();

  test('red strip → pitch 1 with high confidence', () {
    final result = detector.detect(buildCard([220, 30, 30]), 100, 100);
    expect(result, isNotNull);
    expect(result!.pitch, 1);
    expect(result.confidence, greaterThan(0.95));
  });

  test('yellow strip → pitch 2', () {
    final result = detector.detect(buildCard([230, 200, 40]), 100, 100);
    expect(result, isNotNull);
    expect(result!.pitch, 2);
  });

  test('blue strip → pitch 3', () {
    final result = detector.detect(buildCard([40, 90, 220]), 100, 100);
    expect(result, isNotNull);
    expect(result!.pitch, 3);
  });

  test('uniform grey strip → null (non-pitch card)', () {
    // Mid-grey has s≈0, gated out by minSaturation — no votes, no result.
    expect(detector.detect(buildCard([128, 128, 128]), 100, 100), isNull);
  });

  test('dark strip → null (gated by minValue)', () {
    expect(detector.detect(buildCard([10, 10, 10]), 100, 100), isNull);
  });

  test('green strip → null (no hue bucket wins)', () {
    // Green sits between yellow and blue buckets — no bucket clears 0.60.
    expect(detector.detect(buildCard([40, 200, 60]), 100, 100), isNull);
  });
}
