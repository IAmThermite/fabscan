import 'dart:math' as math;
import 'dart:typed_data';

/// DCT-based perceptual hash, ported from the fab-tabletop scanner
/// (`assets/js/card_scanner/p_hash.js`) so on-device hashes match the
/// values precomputed into the bundled card database.
///
/// Pipeline:
///   1. area-average downsample a (sub)region to 32x32 grayscale
///   2. 2D DCT
///   3. take the top-left 8x8 low-frequency block, excluding the DC term
///   4. threshold each coefficient against the median -> 63 bits
///
/// The result is a non-negative 64-bit int (the DC bit is always 0), stored
/// directly as a SQLite INTEGER.
///
/// IMPORTANT: the precompute tool (`tool/build_card_db.dart`) feeds **RGB**
/// pixels here, so callers on-device must also pass RGB (convert any BGR /
/// camera buffers first) for the hashes to line up.
class PHash {
  PHash._();

  static const int dctSize = 32;
  static const int hashSize = 8;

  static final Float64List _cosTable = _buildCosTable();

  static Float64List _buildCosTable() {
    final t = Float64List(dctSize * dctSize);
    for (var i = 0; i < dctSize; i++) {
      for (var j = 0; j < dctSize; j++) {
        t[i * dctSize + j] =
            math.cos(((2 * j + 1) * i * math.pi) / (2 * dctSize));
      }
    }
    return t;
  }

  /// Compute the hash from a packed pixel buffer.
  ///
  /// [pixels] is row-major, [channels] bytes per pixel (1=gray, 3=rgb, 4=rgba).
  /// The optional region (in pixels) restricts the hashed area; it defaults to
  /// the full image.
  static int compute(
    Uint8List pixels,
    int width,
    int height,
    int channels, {
    int regionX = 0,
    int regionY = 0,
    int? regionW,
    int? regionH,
  }) {
    final gray = _resizeToGray(
      pixels,
      width,
      height,
      channels,
      regionX,
      regionY,
      regionW ?? width,
      regionH ?? height,
    );
    final dct = _dct2d(gray);

    final coeffs = <double>[];
    for (var y = 0; y < hashSize; y++) {
      for (var x = 0; x < hashSize; x++) {
        if (x == 0 && y == 0) continue; // skip DC
        coeffs.add(dct[y * dctSize + x]);
      }
    }

    final sorted = Float64List.fromList(coeffs)..sort();
    final mid = sorted.length ~/ 2;
    final median = sorted.length.isEven
        ? (sorted[mid - 1] + sorted[mid]) / 2
        : sorted[mid];

    var hash = 0;
    for (final c in coeffs) {
      hash = (hash << 1) | (c > median ? 1 : 0);
    }
    return hash;
  }

  static Float64List _resizeToGray(
    Uint8List px,
    int width,
    int height,
    int ch,
    int rx,
    int ry,
    int rw,
    int rh,
  ) {
    const n = dctSize;
    final gray = Float64List(n * n);
    for (var oy = 0; oy < n; oy++) {
      final fy0 = ry + (oy * rh) / n;
      final fy1 = ry + ((oy + 1) * rh) / n;
      final y0 = fy0.floor();
      final y1 = math.max(y0 + 1, fy1.ceil());
      for (var ox = 0; ox < n; ox++) {
        final fx0 = rx + (ox * rw) / n;
        final fx1 = rx + ((ox + 1) * rw) / n;
        final x0 = fx0.floor();
        final x1 = math.max(x0 + 1, fx1.ceil());

        var sumR = 0.0, sumG = 0.0, sumB = 0.0;
        var count = 0;
        for (var sy = y0; sy < y1; sy++) {
          if (sy < 0 || sy >= height) continue;
          for (var sx = x0; sx < x1; sx++) {
            if (sx < 0 || sx >= width) continue;
            final idx = (sy * width + sx) * ch;
            if (ch == 1) {
              final v = px[idx].toDouble();
              sumR += v;
              sumG += v;
              sumB += v;
            } else {
              sumR += px[idx];
              sumG += px[idx + 1];
              sumB += px[idx + 2];
            }
            count++;
          }
        }
        if (count == 0) count = 1;
        gray[oy * n + ox] =
            0.299 * (sumR / count) + 0.587 * (sumG / count) + 0.114 * (sumB / count);
      }
    }
    return gray;
  }

  static Float64List _dct2d(Float64List gray) {
    const n = dctSize;
    final rowDct = Float64List(n * n);
    for (var y = 0; y < n; y++) {
      for (var u = 0; u < n; u++) {
        var sum = 0.0;
        for (var x = 0; x < n; x++) {
          sum += gray[y * n + x] * _cosTable[u * n + x];
        }
        rowDct[y * n + u] = sum;
      }
    }
    final result = Float64List(n * n);
    for (var u = 0; u < n; u++) {
      for (var v = 0; v < n; v++) {
        var sum = 0.0;
        for (var y = 0; y < n; y++) {
          sum += rowDct[y * n + u] * _cosTable[v * n + y];
        }
        result[v * n + u] = sum;
      }
    }
    return result;
  }

  /// Hamming distance between two hashes (number of differing bits).
  static int hammingDistance(int a, int b) {
    var x = a ^ b;
    var dist = 0;
    while (x != 0) {
      x &= x - 1;
      dist++;
    }
    return dist;
  }
}
