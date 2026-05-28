import 'dart:typed_data';

import '../models/fab_card.dart';

/// Pure-Dart RGB crop helpers shared by the on-device scanner and the
/// `tool/build_card_db.dart` precompute step.
///
/// Keeping this free of Flutter/OpenCV imports is what lets the CLI tool and
/// the app run *identical* crop + hash code, so the precomputed database
/// hashes line up with what the camera produces.
class ArtCrop {
  ArtCrop(this.rgb, this.width, this.height);

  final Uint8List rgb;
  final int width;
  final int height;

  /// Extracts the art region described by [bbox] (ratios 0..1) from an upright
  /// card RGB buffer.
  static ArtCrop extract(Uint8List cardRgb, int cardW, int cardH, ArtBbox bbox) {
    final x = (bbox.x * cardW).round().clamp(0, cardW - 1);
    final y = (bbox.y * cardH).round().clamp(0, cardH - 1);
    final w = (bbox.w * cardW).round().clamp(1, cardW - x);
    final h = (bbox.h * cardH).round().clamp(1, cardH - y);
    final out = Uint8List(w * h * 3);
    for (var row = 0; row < h; row++) {
      final srcStart = ((y + row) * cardW + x) * 3;
      out.setRange(
        row * w * 3,
        (row + 1) * w * 3,
        cardRgb.sublist(srcStart, srcStart + w * 3),
      );
    }
    return ArtCrop(out, w, h);
  }
}
