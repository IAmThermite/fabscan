/// Geometry of the centered card-capture rectangle, shared by the on-screen
/// alignment guide ([scan_screen]) and the guide-region fallback crop
/// ([CardDetector.captureGuideRegion]). Defining it once guarantees that what
/// the user lines the card up to is exactly what gets cropped and hashed.
class ScanConfig {
  ScanConfig._();

  /// Fraction of the upright frame's width the card occupies.
  static const double captureWidthFactor = 0.72;

  /// Card aspect ratio, width / height (FAB cards are ~1 : 1.4 portrait).
  static const double cardAspect = 1 / 1.4;

  /// Centered capture rectangle (in pixels) within an upright frame of
  /// [width] x [height]. Sized by width, but clamped so it never exceeds the
  /// frame height.
  static (int x, int y, int w, int h) captureRect(int width, int height) {
    var w = (captureWidthFactor * width).round();
    var h = (w / cardAspect).round();
    if (h > height) {
      h = height;
      w = (h * cardAspect).round();
    }
    final x = ((width - w) / 2).round();
    final y = ((height - h) / 2).round();
    return (x, y, w, h);
  }
}
