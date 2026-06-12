import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import '../models/fab_card.dart';
import '../vision/camera_utils.dart';
import '../vision/card_detector.dart';

/// Result of the heavy CV work for one frame, reduced to plain
/// (isolate-sendable) data: the deskewed card RGB the root isolate still needs
/// for OCR/pitch/PNG, plus the precomputed perceptual hashes and overlay quad.
class CvDetection {
  const CvDetection({
    required this.source,
    required this.score,
    required this.quad,
    required this.cardRgb,
    required this.cardWidth,
    required this.cardHeight,
    required this.artBbox,
    required this.artHash,
    required this.fullHash,
  });

  /// "contour" (Canny + deskew) or "guide" (fixed alignment-rect crop).
  final String source;
  final double score;

  /// Detected corners in source-frame pixels (empty for the guide fallback).
  final List<Offset> quad;

  final Uint8List cardRgb;
  final int cardWidth;
  final int cardHeight;
  final ArtBbox artBbox;

  final int? artHash;
  final int? fullHash;

  /// Builds the unified result from an inline [CardDetection], computing its
  /// hashes — used by the root-isolate fallback path when the worker is
  /// unavailable, so both paths feed the same downstream recognition code.
  factory CvDetection.fromDetection(CardDetection d) {
    final hashes = d.computeHashes();
    return CvDetection(
      source: d.source,
      score: d.score,
      quad: d.quad,
      cardRgb: d.cardRgb,
      cardWidth: d.cardWidth,
      cardHeight: d.cardHeight,
      artBbox: d.artBbox,
      artHash: hashes.art,
      fullHash: hashes.full,
    );
  }
}

/// Runs the OpenCV pipeline (YUV→BGR, contour detect/deskew, perceptual hash)
/// on a long-lived background isolate so the heavy, synchronous FFI work never
/// blocks the UI thread.
///
/// `opencv_dart` is pure FFI (no platform channels), so it runs in a plain
/// spawned isolate. If the isolate fails to start — or any request errors — the
/// caller can fall back to running the same pipeline inline; see
/// [ScanController]. Camera and Tesseract (platform-channel plugins) stay on the
/// root isolate.
class CvWorker {
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _responses;
  StreamSubscription<dynamic>? _sub;

  var _nextId = 0;
  final _pending = <int, Completer<CvDetection?>>{};
  var _disposed = false;

  bool get isRunning => _commands != null && !_disposed;

  /// Spawns the worker and completes once it's ready. Throws if the isolate
  /// can't be spawned.
  Future<void> start() async {
    if (_isolate != null) return;
    final responses = ReceivePort();
    _responses = responses;
    final ready = Completer<SendPort>();

    _sub = responses.listen((dynamic msg) {
      if (msg is SendPort) {
        ready.complete(msg);
        return;
      }
      final map = msg as Map<Object?, Object?>;
      final id = map['id'] as int;
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = map['error'];
      if (error != null) {
        completer.completeError(error);
      } else {
        completer.complete(map['result'] as CvDetection?);
      }
    });

    _isolate = await Isolate.spawn(_entry, responses.sendPort,
        debugName: 'cv-worker', errorsAreFatal: false);
    _commands = await ready.future;
  }

  /// Detects + hashes a frame on the worker. Returns null when nothing
  /// card-like is found. Throws if the worker isn't running or errors.
  Future<CvDetection?> process(
    CameraFrame frame,
    int sensorOrientation,
    double minCaptureScore,
  ) {
    return _send({
      'cmd': 'process',
      'frame': frame,
      'orientation': sensorOrientation,
      'minScore': minCaptureScore,
    });
  }

  /// Re-captures a frame with the matched region grown by [scale] (the
  /// expand-retry), reusing the base detection's [baseQuad]/[baseSource].
  /// Stateless: the frame bytes are re-sent rather than the worker retaining a
  /// native Mat between calls.
  Future<CvDetection?> expand(
    CameraFrame frame,
    int sensorOrientation,
    double scale,
    List<Offset> baseQuad,
    String baseSource,
    double baseScore,
  ) {
    return _send({
      'cmd': 'expand',
      'frame': frame,
      'orientation': sensorOrientation,
      'scale': scale,
      'quad': [for (final p in baseQuad) ...[p.dx, p.dy]],
      'source': baseSource,
      'baseScore': baseScore,
    });
  }

  Future<CvDetection?> _send(Map<String, Object?> payload) {
    final commands = _commands;
    if (commands == null || _disposed) {
      throw StateError('CvWorker is not running');
    }
    final id = _nextId++;
    final completer = Completer<CvDetection?>();
    _pending[id] = completer;
    commands.send({...payload, 'id': id, 'reply': _responses!.sendPort});
    return completer.future;
  }

  void dispose() {
    _disposed = true;
    _commands?.send({'cmd': 'shutdown'});
    _sub?.cancel();
    _responses?.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('CvWorker disposed'));
    }
    _pending.clear();
  }

  // --- Worker isolate ---

  static void _entry(SendPort toMain) {
    final commands = ReceivePort();
    toMain.send(commands.sendPort);
    final detector = CardDetector();

    commands.listen((dynamic msg) {
      final map = msg as Map<Object?, Object?>;
      final cmd = map['cmd'] as String;
      if (cmd == 'shutdown') {
        commands.close();
        return;
      }
      final id = map['id'] as int;
      final reply = map['reply'] as SendPort;
      try {
        final result = _handle(detector, cmd, map);
        reply.send({'id': id, 'result': result});
      } catch (e) {
        reply.send({'id': id, 'error': '$e'});
      }
    });
  }

  static CvDetection? _handle(
    CardDetector detector,
    String cmd,
    Map<Object?, Object?> map,
  ) {
    final frame = map['frame'] as CameraFrame;
    final orientation = map['orientation'] as int;
    final bgr = cameraFrameToBgr(frame);
    try {
      if (cmd == 'process') {
        final minScore = map['minScore'] as double;
        final contour = detector.detect(bgr);
        final detection = (contour != null && contour.score >= minScore)
            ? contour
            : detector.captureGuideRegion(bgr, orientation);
        return CvDetection.fromDetection(detection);
      }
      // expand
      final scale = map['scale'] as double;
      final flat = (map['quad'] as List).cast<double>();
      final quad = <Offset>[
        for (var i = 0; i + 1 < flat.length; i += 2) Offset(flat[i], flat[i + 1]),
      ];
      final base = CardDetection(
        quad: quad,
        cardRgb: Uint8List(0),
        cardWidth: 0,
        cardHeight: 0,
        artBbox: detector.artBbox,
        score: map['baseScore'] as double,
        source: map['source'] as String,
      );
      final expanded = detector.expandCapture(bgr, base, orientation, scale);
      return expanded == null ? null : CvDetection.fromDetection(expanded);
    } finally {
      bgr.dispose();
    }
  }
}
