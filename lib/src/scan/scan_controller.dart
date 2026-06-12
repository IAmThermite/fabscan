import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/card_repository.dart';
import '../db/card_dao.dart';
import '../db/recents_store.dart';
import '../vision/art_crop.dart';
import '../vision/camera_utils.dart';
import '../vision/card_detector.dart';
import '../vision/ocr_service.dart';
import '../vision/pitch_detector.dart';
import 'cv_worker.dart';

enum ScanState {
  initializing,
  scanning,
  processing,
  matched,
  noCamera,
  permissionDenied,
  error,
}

/// The live detection overlay (detected contour + the frame it was measured
/// against). Updated on every sampled frame and surfaced via [ScanController.
/// overlay] so the overlay can repaint without rebuilding the whole preview.
class ScanOverlay {
  const ScanOverlay({this.quad, this.frameSize});

  /// Detected card outline in camera-frame pixels, or null (guide fallback /
  /// no detection) — in which case only the static guide box is shown.
  final List<Offset>? quad;
  final Size? frameSize;
}

/// Drives the live scanning loop: samples camera frames, detects a card,
/// computes perceptual hashes (and optionally OCRs the title), then looks the
/// card up in the bundled database.
///
/// Heavy CV work runs inline on every Nth frame guarded by [_busy]; this keeps
/// the skeleton simple. Moving detection to an isolate is a known follow-up.
class ScanController extends ChangeNotifier {
  ScanController({
    required this._repository,
    required this._recents,
    OcrService? ocr,
    CardDetector? detector,
    PitchDetector? pitchDetector,
    this.sampleEvery = 20,
    this.minCaptureScore = 0.55,
    this.runOcr = true,
    this.expandRetryFactor = 0.05,
  }) : _ocr = ocr ?? OcrService(),
       _detector = detector ?? CardDetector(),
       _pitchDetector = pitchDetector ?? const PitchDetector();

  final CardRepository _repository;
  final RecentsStore _recents;
  final OcrService _ocr;
  final CardDetector _detector;
  final PitchDetector _pitchDetector;

  /// Background isolate that runs the heavy OpenCV pipeline. When it can't be
  /// started (or errors at runtime) [_useWorker] flips false and the pipeline
  /// runs inline on the root isolate instead.
  final CvWorker _worker = CvWorker();
  bool _useWorker = false;

  /// Process one frame out of every [sampleEvery] delivered by the stream.
  final int sampleEvery;

  /// Minimum detector score required before we attempt recognition.
  final double minCaptureScore;

  /// Whether to OCR the card title (used as a disambiguation aid / fallback).
  final bool runOcr;

  /// When a card is detected but nothing matches, the capture region is grown
  /// by this fraction (0.05 = +5%) and recognition is retried once, so a card
  /// sleeve or a tight contour clipping the card edge is less likely to defeat
  /// the phash. Set to 0 to disable the retry.
  final double expandRetryFactor;

  /// Camera stream resolution. The detector warps to a fixed 420x588 upright
  /// card regardless of input, so `medium` (~480p) is ample for the phash and
  /// far cheaper to convert/transfer than `high` (~1080p). Bump back to `high`
  /// only if OCR title reads regress at this resolution.
  static const ResolutionPreset streamResolution = ResolutionPreset.medium;

  CameraController? _camera;
  CameraController? get camera => _camera;

  ScanState _state = ScanState.initializing;
  ScanState get state => _state;

  String? errorMessage;

  /// Latest detection overlay (detected card outline + the frame size it was
  /// measured against). Driven on every sampled frame; the preview listens to
  /// this directly so per-frame overlay updates don't rebuild the whole tree.
  final ValueNotifier<ScanOverlay> overlay =
      ValueNotifier<ScanOverlay>(const ScanOverlay());

  RecognitionResult? result;

  int _frameCount = 0;
  bool _busy = false;
  bool _stopped = false;
  int _sensorOrientation = 0;

  /// Camera sensor orientation in degrees (for rotating frames upright).
  int get sensorOrientation => _sensorOrientation;

  Future<void> initialize() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _setState(ScanState.noCamera);
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        streamResolution,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      _camera = controller;
      _sensorOrientation = back.sensorOrientation;
      // Spin up the CV worker isolate. If it can't start, scanning still works
      // via the inline fallback — just without the off-main-thread win.
      await _ensureWorker();
      _setState(ScanState.scanning);
      await controller.startImageStream(_onFrame);
      await _setWakelock(true);
    } on CameraException catch (e) {
      if (e.code == 'CameraAccessDenied') {
        _setState(ScanState.permissionDenied);
      } else {
        errorMessage = e.description ?? e.code;
        _setState(ScanState.error);
      }
    } catch (e) {
      errorMessage = '$e';
      _setState(ScanState.error);
    }
  }

  void _onFrame(CameraImage image) {
    if (_stopped || _busy) return;
    _frameCount++;
    if (_frameCount % sampleEvery != 0) return;
    _busy = true;
    _processFrame(image).whenComplete(() => _busy = false);
  }

  /// Starts the CV worker isolate once. On failure (e.g. opencv_dart can't load
  /// in a spawned isolate) leaves [_useWorker] false so frames process inline.
  Future<void> _ensureWorker() async {
    if (_worker.isRunning) {
      _useWorker = true;
      return;
    }
    try {
      await _worker.start();
      _useWorker = true;
      debugPrint('[fabscan] CV worker started (off-main CV active)');
    } catch (e) {
      debugPrint('[fabscan] CV worker unavailable, using inline CV: $e');
      _useWorker = false;
    }
  }

  Future<void> _processFrame(CameraImage image) async {
    final frame = CameraFrame.fromCameraImage(image);
    if (frame == null) return; // Unexpected format.

    // Heavy CV (YUV→BGR, detect, hash) runs on the worker isolate so the UI
    // thread stays free. If the worker isn't available (failed to start) or a
    // request errors, fall back to running the same pipeline inline.
    if (_useWorker) {
      try {
        final detection =
            await _worker.process(frame, _sensorOrientation, minCaptureScore);
        if (detection == null) return;
        await _runRecognition(
          detection,
          image,
          () => _worker.expand(
            frame,
            _sensorOrientation,
            1 + expandRetryFactor,
            detection.quad,
            detection.source,
            detection.score,
          ),
        );
        return;
      } catch (e) {
        debugPrint('[fabscan] CV worker failed, falling back inline: $e');
        _useWorker = false;
      }
    }
    await _processInline(frame, image);
  }

  /// Inline (root-isolate) CV path: the fallback when the worker is
  /// unavailable. Mirrors what the worker does, keeping the BGR Mat alive for a
  /// possible expand-retry.
  Future<void> _processInline(CameraFrame frame, CameraImage image) async {
    final bgr = cameraFrameToBgr(frame);
    try {
      final contour = _detector.detect(bgr);
      final detection = (contour != null && contour.score >= minCaptureScore)
          ? contour
          : _detector.captureGuideRegion(bgr, _sensorOrientation);
      await _runRecognition(
        CvDetection.fromDetection(detection),
        image,
        () async {
          final expanded = _detector.expandCapture(
              bgr, detection, _sensorOrientation, 1 + expandRetryFactor);
          return expanded == null ? null : CvDetection.fromDetection(expanded);
        },
      );
    } finally {
      bgr.dispose();
    }
  }

  /// Shared recognition flow for a detection (from either the worker or the
  /// inline path): updates the overlay, runs gated OCR/pitch, then recognition
  /// with a single expand-retry via [expand].
  Future<void> _runRecognition(
    CvDetection detection,
    CameraImage image,
    Future<CvDetection?> Function() expand,
  ) async {
    // Only draw the contour outline; the guide box is always shown separately.
    // Update the overlay notifier directly — this repaints just the overlay,
    // not the whole preview tree.
    overlay.value = ScanOverlay(
      quad: detection.source == 'contour' ? detection.quad : null,
      frameSize: Size(image.width.toDouble(), image.height.toDouble()),
    );

    // OCR (and the pitch vote it feeds) is only a disambiguation aid for the
    // title arm, yet Tesseract costs ~0.5-1s. Run it only on a confident
    // contour detection — the `guide` fallback fires every frame even when
    // pointing at nothing, and the phash arm handles the no-OCR path. Pitch is
    // only used in the title arm, so it's gated on the same condition.
    String? title;
    double? ocrConfidence;
    OcrResult? ocr;
    PitchResult? pitch;
    if (_shouldReadTitle(detection)) {
      ocr = await _ocr.readTitle(
        detection.cardRgb,
        detection.cardWidth,
        detection.cardHeight,
      );
      title = ocr.text;
      ocrConfidence = ocr.confidence;
      pitch = _pitchDetector.detect(
        detection.cardRgb,
        detection.cardWidth,
        detection.cardHeight,
      );
    }

    // Diagnostics: log the closest candidates (ignoring thresholds) so poor
    // matching can be debugged from logcat even when nothing matches.
    if (kDebugMode) {
      final closest = await _repository.diagnoseClosest(
        ScanHashes(art: detection.artHash, full: detection.fullHash),
      );
      final summary = closest
          .map((m) => '${m.printId} ${m.arm}=${m.distance}')
          .join(', ');
      debugPrint(
        '[fabscan] source=${detection.source} '
        'score=${detection.score.toStringAsFixed(2)} '
        'ocr="${title ?? ''}" conf=${ocrConfidence?.toStringAsFixed(0) ?? '-'} '
        'pitch=${pitch?.pitch ?? '-'} '
        'closest: $summary',
      );
    }

    var match = await _recognize(
      detection,
      title: title,
      ocrConfidence: ocrConfidence,
      pitch: pitch,
    );
    // Track which detection actually matched so we encode its capture PNGs
    // (and only its) once, below.
    var matchedDetection = detection;

    // A card sleeve or a tight contour can clip the card edge so nothing
    // matches; retry once with the capture region grown by [expandRetryFactor].
    if (match == null && expandRetryFactor > 0) {
      final expanded = await expand();
      if (expanded != null) {
        match = await _recognize(
          expanded,
          title: title,
          ocrConfidence: ocrConfidence,
          pitch: pitch,
        );
        if (match != null) matchedDetection = expanded;
      }
    }

    if (match != null) {
      await _finalize(_attachCaptures(match, matchedDetection, ocr));
    }
  }

  /// Whether to OCR the title for this detection. Only confident contour
  /// detections qualify (a contour is only kept when its score already clears
  /// [minCaptureScore]); the cheap phash arm carries every other frame.
  bool _shouldReadTitle(CvDetection detection) =>
      runOcr && detection.source == 'contour';

  /// Runs recognition for [detection] using its precomputed hashes, reusing the
  /// already-read OCR [title] so a retry doesn't re-OCR. No PNG encoding here —
  /// the capture previews are encoded once, after a match, in [_attachCaptures].
  Future<RecognitionResult?> _recognize(
    CvDetection detection, {
    required String? title,
    required double? ocrConfidence,
    required PitchResult? pitch,
  }) {
    return _repository.recognize(
      ScanHashes(art: detection.artHash, full: detection.fullHash),
      ocrTitle: title,
      ocrConfidence: ocrConfidence,
      detectedPitch: pitch?.pitch,
      pitchConfidence: pitch?.confidence,
      detectorScore: detection.score,
      detectSource: detection.source,
    );
  }

  /// Encodes the capture previews for the [detection] that produced [match] and
  /// attaches them to the result's debug payload. Runs once per successful scan
  /// (not per sampled frame), so the PNG encoding stays off the hot loop while
  /// the debug panel still shows the matching pass.
  RecognitionResult _attachCaptures(
    RecognitionResult match,
    CvDetection detection,
    OcrResult? ocr,
  ) {
    final art = ArtCrop.extract(
      detection.cardRgb,
      detection.cardWidth,
      detection.cardHeight,
      detection.artBbox,
    );
    return match.withDebug(
      match.debug.withCaptures(
        capturedCardPng: _encodeRgbPng(
          detection.cardRgb,
          detection.cardWidth,
          detection.cardHeight,
        ),
        capturedArtPng: _encodeRgbPng(art.rgb, art.width, art.height),
        capturedTitleRawPng: ocr?.rawPng,
        capturedTitleOcrPng: ocr?.processedPng,
      ),
    );
  }

  /// Encodes a packed RGB buffer to a PNG for the debug panel previews.
  Uint8List? _encodeRgbPng(Uint8List rgb, int width, int height) {
    try {
      final image = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rgb.buffer,
        numChannels: 3,
        order: img.ChannelOrder.rgb,
      );
      return img.encodePng(image);
    } catch (_) {
      return null;
    }
  }

  Future<void> _finalize(RecognitionResult match) async {
    _stopped = true;
    result = match;
    await _recents.record(match.card, match.matchedPrint);
    try {
      await _camera?.stopImageStream();
    } catch (_) {}
    await _setWakelock(false);
    _setState(ScanState.matched);
  }

  /// Stops the scan loop when the app is backgrounded. The OS may reclaim the
  /// camera, so we stop the stream and release the wakelock; [handleAppResumed]
  /// re-acquires the camera on return.
  Future<void> handleAppPaused() async {
    await _setWakelock(false);
    final cam = _camera;
    if (cam == null) return;
    try {
      if (cam.value.isStreamingImages) await cam.stopImageStream();
    } catch (_) {}
  }

  /// Re-acquires the camera when the app returns to the foreground. Android
  /// releases the camera while backgrounded, leaving the old controller dead
  /// (no frames delivered), so we dispose it and re-initialize rather than
  /// restart the stream on a stale controller. No-op while a result is shown.
  Future<void> handleAppResumed() async {
    if (_state == ScanState.matched) return;
    final old = _camera;
    _camera = null;
    try {
      await old?.dispose();
    } catch (_) {}
    _stopped = false;
    _frameCount = 0;
    await initialize();
  }

  Future<void> _setWakelock(bool enable) async {
    try {
      await WakelockPlus.toggle(enable: enable);
    } catch (_) {}
  }

  /// Resumes scanning after the user dismisses a result.
  Future<void> resume() async {
    if (_camera == null) return;
    result = null;
    overlay.value = const ScanOverlay();
    _stopped = false;
    _frameCount = 0;
    _setState(ScanState.scanning);
    try {
      if (!_camera!.value.isStreamingImages) {
        await _camera!.startImageStream(_onFrame);
      }
      await _setWakelock(true);
    } catch (e) {
      errorMessage = '$e';
      _setState(ScanState.error);
    }
  }

  void _setState(ScanState s) {
    _state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopped = true;
    final cam = _camera;
    _camera = null;
    _setWakelock(false);
    () async {
      try {
        if (cam?.value.isStreamingImages ?? false) {
          await cam?.stopImageStream();
        }
      } catch (_) {}
      await cam?.dispose();
    }();
    _worker.dispose();
    overlay.dispose();
    super.dispose();
  }
}
