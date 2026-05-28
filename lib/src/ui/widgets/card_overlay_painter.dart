import 'package:flutter/material.dart';

/// Draws the detected card outline over the camera preview.
///
/// The detector reports corners in camera-frame pixel coordinates, which on
/// Android are rotated relative to the on-screen preview. We rotate by
/// [quarterTurns] (derived from the sensor orientation) and scale with a
/// cover fit so the outline lines up with what the user sees.
class CardOverlayPainter extends CustomPainter {
  CardOverlayPainter({
    required this.quad,
    required this.frameSize,
    required this.quarterTurns,
    required this.color,
  });

  final List<Offset>? quad;
  final Size? frameSize;
  final int quarterTurns;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final quad = this.quad;
    final frame = frameSize;
    if (quad == null || quad.length != 4 || frame == null) return;

    // Frame dimensions after applying the sensor rotation.
    final rotated = quarterTurns.isOdd;
    final fw = rotated ? frame.height : frame.width;
    final fh = rotated ? frame.width : frame.height;
    final scale =
        (size.width / fw).clamp(0.0, double.infinity) > (size.height / fh)
            ? size.width / fw
            : size.height / fh;
    final dx = (size.width - fw * scale) / 2;
    final dy = (size.height - fh * scale) / 2;

    Offset map(Offset p) {
      // Rotate point from frame space into preview space.
      Offset r;
      switch (quarterTurns & 3) {
        case 1:
          r = Offset(frame.height - p.dy, p.dx);
          break;
        case 2:
          r = Offset(frame.width - p.dx, frame.height - p.dy);
          break;
        case 3:
          r = Offset(p.dy, frame.width - p.dx);
          break;
        default:
          r = p;
      }
      return Offset(r.dx * scale + dx, r.dy * scale + dy);
    }

    final path = Path()..moveTo(map(quad[0]).dx, map(quad[0]).dy);
    for (var i = 1; i < 4; i++) {
      final m = map(quad[i]);
      path.lineTo(m.dx, m.dy);
    }
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: 0.12),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant CardOverlayPainter old) =>
      old.quad != quad || old.frameSize != frameSize || old.color != color;
}
