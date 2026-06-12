// HSV vote-based detection of a Flesh and Blood card's pitch colour
// (1 = red, 2 = yellow, 3 = blue) from the coloured strip at the top of an
// upright, deskewed card.
//
// Pure Dart on top of a packed RGB buffer; no Flutter / OpenCV imports so it
// can be unit-tested in isolation and called inline on every frame.
import 'dart:math' as math;
import 'dart:typed_data';

/// The detected pitch and the share of voting pixels that supported it.
class PitchResult {
  const PitchResult({required this.pitch, required this.confidence});

  /// 1 = red, 2 = yellow, 3 = blue.
  final int pitch;

  /// Winning hue's share of all pixels that passed the saturation/value gates
  /// (0..1). Equal to or above [PitchDetector.threshold].
  final double confidence;
}

/// Detects a FAB card's pitch from the coloured pixels in a thin top-strip
/// sample region. Returns null when no hue wins by a clear margin — non-pitch
/// cards (equipment, weapons), uncertain lighting, or atypical art will fall
/// through to null rather than guess.
class PitchDetector {
  const PitchDetector({
    this.y0Ratio = 0.01,
    this.y1Ratio = 0.04,
    this.x0Ratio = 0.25,
    this.x1Ratio = 0.75,
    this.minSaturation = 0.20,
    this.minValue = 0.15,
    this.threshold = 0.60,
  });

  /// Sample window as ratios of the upright card. Defaults match the
  /// reference scanner: Y 1–4%, X 25–75% — the coloured border strip just
  /// below the top edge, away from the corners.
  final double y0Ratio;
  final double y1Ratio;
  final double x0Ratio;
  final double x1Ratio;

  /// HSV gates: pixels below either threshold are skipped (drops neutrals,
  /// dark text and shadow).
  final double minSaturation;
  final double minValue;

  /// Minimum share of voting pixels a hue must win to be accepted.
  final double threshold;

  /// Detects pitch from a packed RGB card buffer (the same buffer
  /// [CardDetector] hashes). Returns null when no hue clears [threshold].
  PitchResult? detect(Uint8List rgb, int width, int height) {
    final y0 = (height * y0Ratio).round().clamp(0, height - 1);
    final y1 = (height * y1Ratio).round().clamp(y0 + 1, height);
    final x0 = (width * x0Ratio).round().clamp(0, width - 1);
    final x1 = (width * x1Ratio).round().clamp(x0 + 1, width);

    var red = 0, yellow = 0, blue = 0, total = 0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final i = (y * width + x) * 3;
        final r = rgb[i].toDouble();
        final g = rgb[i + 1].toDouble();
        final b = rgb[i + 2].toDouble();
        final maxC = math.max(r, math.max(g, b));
        final minC = math.min(r, math.min(g, b));
        final delta = maxC - minC;
        final v = maxC / 255.0;
        final s = maxC == 0 ? 0.0 : delta / maxC;
        if (s < minSaturation || v < minValue) continue;

        // Standard RGB→HSV hue, in degrees 0..360. Dart's `%` is Euclidean so
        // negative numerators wrap positively without an explicit `< 0` fix.
        double h = 0;
        if (delta > 0) {
          if (maxC == r) {
            h = 60 * (((g - b) / delta) % 6);
          } else if (maxC == g) {
            h = 60 * ((b - r) / delta + 2);
          } else {
            h = 60 * ((r - g) / delta + 4);
          }
        }

        total++;
        if (h < 25 || h > 340) {
          red++;
        } else if (h >= 25 && h <= 65) {
          yellow++;
        } else if (h >= 190 && h <= 260) {
          blue++;
        }
      }
    }
    if (total == 0) return null;
    final rr = red / total;
    final ry = yellow / total;
    final rb = blue / total;
    if (rr > threshold) return PitchResult(pitch: 1, confidence: rr);
    if (ry > threshold) return PitchResult(pitch: 2, confidence: ry);
    if (rb > threshold) return PitchResult(pitch: 3, confidence: rb);
    return null;
  }
}
