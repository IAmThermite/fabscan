import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../models/fab_card.dart';
import 'art_crop.dart';
import 'phash.dart';
import 'scan_config.dart';

/// Result of locating a card within a frame.
class CardDetection {
  CardDetection({
    required this.quad,
    required this.cardRgb,
    required this.cardWidth,
    required this.cardHeight,
    required this.artBbox,
    required this.score,
    this.source = 'contour',
  });

  /// The four detected corners in source-image pixel coordinates, ordered
  /// top-left, top-right, bottom-right, bottom-left. Useful for drawing the
  /// live overlay.
  final List<Offset> quad;

  /// The deskewed, upright card as packed RGB bytes.
  final Uint8List cardRgb;
  final int cardWidth;
  final int cardHeight;

  /// Art crop ratios used for the art-region hash.
  final ArtBbox artBbox;

  /// Detection confidence (higher is better); see [_CardDetector] scoring.
  final double score;

  /// How the card was located: "contour" (Canny + deskew) or "guide"
  /// (fixed alignment-rectangle crop — used when no edge is detectable).
  final String source;

  /// Computes the perceptual hashes for this detection (art crop + full card).
  ScanHashesResult computeHashes() {
    final art = ArtCrop.extract(cardRgb, cardWidth, cardHeight, artBbox);
    final artHash = PHash.compute(art.rgb, art.width, art.height, 3);
    final fullHash = PHash.compute(cardRgb, cardWidth, cardHeight, 3);
    return ScanHashesResult(art: artHash, full: fullHash);
  }
}

/// Lightweight container so the detector doesn't depend on the DAO layer.
class ScanHashesResult {
  const ScanHashesResult({this.art, this.full});
  final int? art;
  final int? full;
}

/// Detects a Flesh and Blood card in a BGR frame and returns the deskewed
/// upright card. Ported from the fab-tabletop scanner_worker.js logic.
class CardDetector {
  CardDetector({this.artBbox = ArtBbox.defaultRegular});

  /// Canonical upright card size (~1.4 portrait aspect, like a real FAB card).
  static const int cardWidth = 420;
  static const int cardHeight = 588;

  static const double minAreaRatio = 0.05;
  static const double maxAreaRatio = 0.60;
  static const double minAspect = 1.1;
  static const double maxAspect = 2.0;
  static const double targetAspect = 1.4;
  static const double minSideRatio = 0.75;
  static const double maxCornerDeviationDeg = 25.0;

  /// The four edge-detection passes from the reference scanner.
  static const List<List<int>> _strategies = [
    // [blur, cannyLow, cannyHigh, dilations]
    [5, 30, 100, 2],
    [5, 15, 60, 2],
    [3, 50, 150, 1],
    [7, 20, 80, 3],
  ];

  final ArtBbox artBbox;

  /// Decodes encoded image bytes (e.g. a JPEG from `takePicture`) and detects.
  CardDetection? detectFromBytes(Uint8List encoded) {
    final mat = cv.imdecode(encoded, cv.IMREAD_COLOR);
    try {
      return detect(mat);
    } finally {
      mat.dispose();
    }
  }

  /// Fallback capture when no card edge is detectable (e.g. a black-bordered
  /// card on a dark mat). Rotates the BGR frame upright using the sensor
  /// orientation, then crops the fixed centered [ScanConfig] rectangle — the
  /// same region the on-screen guide shows. No edge detection, so it works on
  /// any background. Assumes the card is roughly flat-on and fills the guide.
  ///
  /// [scale] grows (>1) or shrinks (<1) the crop about its centre, clamped to
  /// the frame; used by [expandCapture] to retry recognition with a wider crop.
  CardDetection captureGuideRegion(cv.Mat src, int sensorOrientation,
      {double scale = 1.0}) {
    final turns = (sensorOrientation ~/ 90) % 4;
    final cv.Mat upright = switch (turns) {
      1 => cv.rotate(src, cv.ROTATE_90_CLOCKWISE),
      2 => cv.rotate(src, cv.ROTATE_180),
      3 => cv.rotate(src, cv.ROTATE_90_COUNTERCLOCKWISE),
      _ => src.clone(),
    };
    try {
      final (rx, ry, rw, rh) = _scaleRect(
        ScanConfig.captureRect(upright.width, upright.height),
        scale,
        upright.width,
        upright.height,
      );
      final roi = upright.region(cv.Rect(rx, ry, rw, rh));
      final resized = cv.resize(roi, (cardWidth, cardHeight));
      final rgbMat = cv.cvtColor(resized, cv.COLOR_BGR2RGB);
      final rgb = Uint8List.fromList(rgbMat.data);
      roi.dispose();
      resized.dispose();
      rgbMat.dispose();
      return CardDetection(
        quad: const <Offset>[],
        cardRgb: rgb,
        cardWidth: cardWidth,
        cardHeight: cardHeight,
        artBbox: artBbox,
        score: 1.0,
        source: 'guide',
      );
    } finally {
      upright.dispose();
    }
  }

  /// Re-captures [base] with its source region grown about its centre by
  /// [scale] (e.g. 1.05 = +5%). A card sleeve, or a contour that locked onto
  /// the inner frame rather than the card edge, can clip the capture so the
  /// hash misses; a slightly wider crop recovers the full card for a second
  /// recognition attempt. Returns null when there's no region to expand (a
  /// contour detection with no quad).
  CardDetection? expandCapture(
      cv.Mat src, CardDetection base, int sensorOrientation, double scale) {
    if (base.source == 'guide') {
      return captureGuideRegion(src, sensorOrientation, scale: scale);
    }
    if (base.quad.length != 4) return null;
    var cx = 0.0, cy = 0.0;
    for (final p in base.quad) {
      cx += p.dx;
      cy += p.dy;
    }
    cx /= 4;
    cy /= 4;
    final scaled = base.quad
        .map((p) => [
              (cx + (p.dx - cx) * scale).clamp(0.0, (src.width - 1).toDouble()),
              (cy + (p.dy - cy) * scale).clamp(0.0, (src.height - 1).toDouble()),
            ])
        .toList();
    return _warp(src, scaled, base.score);
  }

  /// Scales a rect about its centre by [scale], clamped to [maxW] x [maxH].
  (int, int, int, int) _scaleRect(
      (int, int, int, int) rect, double scale, int maxW, int maxH) {
    final (x, y, w, h) = rect;
    final cx = x + w / 2, cy = y + h / 2;
    var nw = (w * scale).round().clamp(1, maxW);
    var nh = (h * scale).round().clamp(1, maxH);
    final nx = (cx - nw / 2).round().clamp(0, maxW - nw);
    final ny = (cy - nh / 2).round().clamp(0, maxH - nh);
    return (nx, ny, nw, nh);
  }

  /// Detects a card in a BGR [src] Mat. Returns null if none is found.
  CardDetection? detect(cv.Mat src) {
    final imgArea = src.width * src.height;
    final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
    final kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));

    List<List<double>>? bestQuad;
    var bestScore = 0.0;

    try {
      for (final s in _strategies) {
        final blur = s[0];
        final blurred = cv.gaussianBlur(gray, (blur, blur), 0);
        final edges = cv.canny(blurred, s[1].toDouble(), s[2].toDouble());
        final dilated = cv.dilate(edges, kernel, iterations: s[3]);
        final (contours, hierarchy) =
            cv.findContours(dilated, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);

        for (final contour in contours) {
          final area = cv.contourArea(contour);
          if (area < imgArea * minAreaRatio || area > imgArea * maxAreaRatio) {
            continue;
          }
          final quad = _approxQuad(contour);
          if (quad == null) continue;

          final score = _score(quad, src.width, src.height);
          if (score > bestScore) {
            bestScore = score;
            bestQuad = quad;
          }
        }

        blurred.dispose();
        edges.dispose();
        dilated.dispose();
        contours.dispose();
        hierarchy.dispose();

        // A confident detection early lets us skip the slower passes.
        if (bestScore > 0.85) break;
      }
    } finally {
      gray.dispose();
      kernel.dispose();
    }

    if (bestQuad == null) return null;
    return _warp(src, bestQuad, bestScore);
  }

  /// Tries increasing epsilons to fit a 4-point polygon to a contour.
  List<List<double>>? _approxQuad(cv.VecPoint contour) {
    final peri = cv.arcLength(contour, true);
    for (var eps = 0.02; eps <= 0.10 + 1e-9; eps += 0.01) {
      final approx = cv.approxPolyDP(contour, eps * peri, true);
      try {
        if (approx.length == 4) {
          return approx.toList().map((p) => [p.x.toDouble(), p.y.toDouble()]).toList();
        }
      } finally {
        approx.dispose();
      }
    }
    return null;
  }

  /// Orders corners TL, TR, BR, BL by coordinate sums/differences.
  List<List<double>> _orderCorners(List<List<double>> pts) {
    final bySum = [...pts]..sort((a, b) => (a[0] + a[1]).compareTo(b[0] + b[1]));
    final tl = bySum.first;
    final br = bySum.last;
    final rest = pts.where((p) => p != tl && p != br).toList();
    rest.sort((a, b) => (a[0] - a[1]).compareTo(b[0] - b[1]));
    final bl = rest.first; // smaller x-y
    final tr = rest.last;
    return [tl, tr, br, bl];
  }

  double _dist(List<double> a, List<double> b) =>
      math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2));

  /// Geometric quality score in roughly 0..1 combining rectangularity,
  /// aspect fit and centering. Operates on the 4 unordered corner points.
  double _score(List<List<double>> pts, int imgW, int imgH) {
    final c = _orderCorners(pts);
    final tl = c[0], tr = c[1], br = c[2], bl = c[3];

    final topW = _dist(tl, tr);
    final bottomW = _dist(bl, br);
    final leftH = _dist(tl, bl);
    final rightH = _dist(tr, br);

    final w = (topW + bottomW) / 2;
    final h = (leftH + rightH) / 2;
    if (w < 1 || h < 1) return 0;

    // Opposite-side similarity (rejects trapezoids).
    final widthRatio = math.min(topW, bottomW) / math.max(topW, bottomW);
    final heightRatio = math.min(leftH, rightH) / math.max(leftH, rightH);
    if (widthRatio < minSideRatio || heightRatio < minSideRatio) return 0;

    // Aspect (longer side / shorter side).
    final longSide = math.max(w, h);
    final shortSide = math.min(w, h);
    final aspect = longSide / shortSide;
    if (aspect < minAspect || aspect > maxAspect) return 0;

    // Corner angles must be near 90°.
    final corners = [tl, tr, br, bl];
    var maxDev = 0.0;
    for (var i = 0; i < 4; i++) {
      final prev = corners[(i + 3) % 4];
      final cur = corners[i];
      final next = corners[(i + 1) % 4];
      final v1 = [prev[0] - cur[0], prev[1] - cur[1]];
      final v2 = [next[0] - cur[0], next[1] - cur[1]];
      final dot = v1[0] * v2[0] + v1[1] * v2[1];
      final m1 = math.sqrt(v1[0] * v1[0] + v1[1] * v1[1]);
      final m2 = math.sqrt(v2[0] * v2[0] + v2[1] * v2[1]);
      if (m1 == 0 || m2 == 0) return 0;
      final angle = math.acos((dot / (m1 * m2)).clamp(-1.0, 1.0)) * 180 / math.pi;
      maxDev = math.max(maxDev, (angle - 90).abs());
    }
    if (maxDev > maxCornerDeviationDeg) return 0;

    final rectScore = (widthRatio + heightRatio) / 2 * (1 - maxDev / maxCornerDeviationDeg);

    // Centering.
    final cx = (tl[0] + tr[0] + br[0] + bl[0]) / 4;
    final cy = (tl[1] + tr[1] + br[1] + bl[1]) / 4;
    final maxDist = math.sqrt(imgW * imgW + imgH * imgH) / 2;
    final dist = math.sqrt(math.pow(cx - imgW / 2, 2) + math.pow(cy - imgH / 2, 2));
    final centerScore = 1 - (dist / maxDist).clamp(0.0, 1.0);

    // Aspect fit.
    final aspectFit = 1 - ((aspect - targetAspect).abs() / (maxAspect - minAspect)).clamp(0.0, 1.0);

    return rectScore * 0.5 + centerScore * 0.3 + aspectFit * 0.2;
  }

  CardDetection _warp(cv.Mat src, List<List<double>> rawQuad, double score) {
    final c = _orderCorners(rawQuad);
    var tl = c[0], tr = c[1], br = c[2], bl = c[3];

    // If the card sits landscape in the frame, rotate the corner labelling so
    // the short edge maps to the top — yielding an upright portrait warp.
    final topW = _dist(tl, tr);
    final leftH = _dist(tl, bl);
    if (topW > leftH) {
      final old = [tl, tr, br, bl];
      tl = old[3];
      tr = old[0];
      br = old[1];
      bl = old[2];
    }

    final srcPts = cv.VecPoint.fromList([
      cv.Point(tl[0].round(), tl[1].round()),
      cv.Point(tr[0].round(), tr[1].round()),
      cv.Point(br[0].round(), br[1].round()),
      cv.Point(bl[0].round(), bl[1].round()),
    ]);
    final dstPts = cv.VecPoint.fromList([
      cv.Point(0, 0),
      cv.Point(cardWidth - 1, 0),
      cv.Point(cardWidth - 1, cardHeight - 1),
      cv.Point(0, cardHeight - 1),
    ]);

    final m = cv.getPerspectiveTransform(srcPts, dstPts);
    final warpedBgr = cv.warpPerspective(src, m, (cardWidth, cardHeight));
    final warpedRgb = cv.cvtColor(warpedBgr, cv.COLOR_BGR2RGB);

    // Copy the RGB bytes out before disposing the native Mats.
    final rgb = Uint8List.fromList(warpedRgb.data);

    srcPts.dispose();
    dstPts.dispose();
    m.dispose();
    warpedBgr.dispose();
    warpedRgb.dispose();

    return CardDetection(
      quad: [
        Offset(c[0][0], c[0][1]),
        Offset(c[1][0], c[1][1]),
        Offset(c[2][0], c[2][1]),
        Offset(c[3][0], c[3][1]),
      ],
      cardRgb: rgb,
      cardWidth: cardWidth,
      cardHeight: cardHeight,
      artBbox: artBbox,
      score: score,
    );
  }
}
