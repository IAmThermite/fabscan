import 'dart:typed_data';

import 'package:fabscan/src/vision/phash.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds an RGB buffer of [w]x[h] from a per-pixel color function.
Uint8List _rgb(int w, int h, List<int> Function(int x, int y) color) {
  final out = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = color(x, y);
      final i = (y * w + x) * 3;
      out[i] = c[0];
      out[i + 1] = c[1];
      out[i + 2] = c[2];
    }
  }
  return out;
}

void main() {
  group('PHash', () {
    test('identical images produce identical hashes', () {
      img(int x, int y) => [(x * 7) & 0xff, (y * 11) & 0xff, (x ^ y) & 0xff];
      final a = _rgb(64, 90, img);
      final b = _rgb(64, 90, img);
      expect(
        PHash.compute(a, 64, 90, 3),
        PHash.compute(b, 64, 90, 3),
      );
    });

    test('hamming distance of a hash with itself is zero', () {
      final px = _rgb(64, 90, (x, y) => [x & 0xff, y & 0xff, 128]);
      final h = PHash.compute(px, 64, 90, 3);
      expect(PHash.hammingDistance(h, h), 0);
    });

    test('a small perturbation stays close (low hamming distance)', () {
      base(int x, int y) => [(x * 3) & 0xff, (y * 5) & 0xff, ((x + y) * 2) & 0xff];
      final a = _rgb(80, 110, base);
      // Add mild noise to a few pixels.
      final b = _rgb(80, 110, (x, y) {
        final c = base(x, y);
        if ((x + y) % 17 == 0) c[0] = (c[0] + 6) & 0xff;
        return c;
      });
      final d = PHash.hammingDistance(
        PHash.compute(a, 80, 110, 3),
        PHash.compute(b, 80, 110, 3),
      );
      expect(d, lessThan(15)); // well under the art-match threshold
    });

    test('very different images are far apart', () {
      final a = _rgb(64, 64, (x, y) => [255, 255, 255]);
      final b = _rgb(64, 64, (x, y) => [(x < 32) ? 0 : 255, y & 0xff, 64]);
      final d = PHash.hammingDistance(
        PHash.compute(a, 64, 64, 3),
        PHash.compute(b, 64, 64, 3),
      );
      expect(d, greaterThan(5));
    });

    test('hash is a non-negative 64-bit int (DC bit unset)', () {
      final px = _rgb(50, 70, (x, y) => [x & 0xff, y & 0xff, (x * y) & 0xff]);
      final h = PHash.compute(px, 50, 70, 3);
      expect(h, greaterThanOrEqualTo(0));
    });

    test('region restriction hashes only the sub-rectangle', () {
      // Left half is a gradient; right half is constant noise.
      pattern(int x, int y) =>
          x < 40 ? [x & 0xff, y & 0xff, 0] : [200, 50, 100];
      final px = _rgb(80, 80, pattern);
      // Hashing only the left region should match a standalone left image.
      final left = _rgb(40, 80, (x, y) => [x & 0xff, y & 0xff, 0]);
      expect(
        PHash.compute(px, 80, 80, 3, regionX: 0, regionY: 0, regionW: 40, regionH: 80),
        PHash.compute(left, 40, 80, 3),
      );
    });
  });
}
