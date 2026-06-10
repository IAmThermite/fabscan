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

enum ScanState {
  initializing,
  scanning,
  processing,
  matched,
  noCamera,
  permissionDenied,
  error,
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
    this.sampleEvery = 20,
    this.minCaptureScore = 0.55,
    this.runOcr = true,
    this.expandRetryFactor = 0.05,
  }) : _ocr = ocr ?? OcrService(),
       _detector = detector ?? CardDetector();

  final CardRepository _repository;
  final RecentsStore _recents;
  final OcrService _ocr;
  final CardDetector _detector;

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

  CameraController? _camera;
  CameraController? get camera => _camera;

  ScanState _state = ScanState.initializing;
  ScanState get state => _state;

  String? errorMessage;

  /// Latest detected card outline (in camera-frame pixel coordinates) and the
  /// frame size it was measured against, for drawing the live overlay.
  List<Offset>? lastQuad;
  Size? frameSize;

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
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      _camera = controller;
      _sensorOrientation = back.sensorOrientation;
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

  Future<void> _processFrame(CameraImage image) async {
    final bgr = cameraImageToBgr(image);
    if (bgr == null) return;
    try {
      // Try edge-based contour detection; if it fails or is low-confidence
      // (e.g. a black-bordered card on a dark mat), fall back to cropping the
      // fixed alignment-guide rectangle.
      final contour = _detector.detect(bgr);
      final detection = (contour != null && contour.score >= minCaptureScore)
          ? contour
          : _detector.captureGuideRegion(bgr, _sensorOrientation);

      frameSize = Size(image.width.toDouble(), image.height.toDouble());
      // Only draw the contour outline; the guide box is always shown separately.
      lastQuad = detection.source == 'contour' ? detection.quad : null;
      notifyListeners();

      String? title;
      double? ocrConfidence;
      OcrResult? ocr;
      if (runOcr) {
        ocr = await _ocr.readTitle(
          detection.cardRgb,
          detection.cardWidth,
          detection.cardHeight,
        );
        title = ocr.text;
        ocrConfidence = ocr.confidence;
      }

      // Diagnostics: log the closest candidates (ignoring thresholds) so poor
      // matching can be debugged from logcat even when nothing matches.
      if (kDebugMode) {
        final hashes = detection.computeHashes();
        final closest = await _repository.diagnoseClosest(
          ScanHashes(art: hashes.art, full: hashes.full),
        );
        final summary = closest
            .map((m) => '${m.printId} ${m.arm}=${m.distance}')
            .join(', ');
        debugPrint(
          '[fabscan] source=${detection.source} '
          'score=${detection.score.toStringAsFixed(2)} '
          'ocr="${title ?? ''}" conf=${ocrConfidence?.toStringAsFixed(0) ?? '-'} '
          'closest: $summary',
        );
      }

      var match = await _recognize(
        detection,
        title: title,
        ocrConfidence: ocrConfidence,
        ocr: ocr,
      );

      // A card sleeve or a tight contour can clip the card edge so nothing
      // matches; retry once with the capture region grown by [expandRetryFactor].
      if (match == null && expandRetryFactor > 0) {
        final expanded = _detector.expandCapture(
          bgr,
          detection,
          _sensorOrientation,
          1 + expandRetryFactor,
        );
        if (expanded != null) {
          match = await _recognize(
            expanded,
            title: title,
            ocrConfidence: ocrConfidence,
            ocr: ocr,
          );
        }
      }

      if (match != null) {
        await _finalize(match);
      }
    } finally {
      bgr.dispose();
    }
  }

  /// Computes hashes for [detection] and runs recognition, reusing the already
  /// read [ocr] title so a retry doesn't re-OCR. The captured PNGs reflect the
  /// crop that was actually hashed, so the debug panel shows the matching pass.
  Future<RecognitionResult?> _recognize(
    CardDetection detection, {
    required String? title,
    required double? ocrConfidence,
    required OcrResult? ocr,
  }) async {
    final hashes = detection.computeHashes();
    final art = ArtCrop.extract(
      detection.cardRgb,
      detection.cardWidth,
      detection.cardHeight,
      detection.artBbox,
    );
    return _repository.recognize(
      ScanHashes(art: hashes.art, full: hashes.full),
      ocrTitle: title,
      ocrConfidence: ocrConfidence,
      detectorScore: detection.score,
      detectSource: detection.source,
      capturedCardPng: _encodeRgbPng(
        detection.cardRgb,
        detection.cardWidth,
        detection.cardHeight,
      ),
      capturedArtPng: _encodeRgbPng(art.rgb, art.width, art.height),
      capturedTitleRawPng: ocr?.rawPng,
      capturedTitleOcrPng: ocr?.processedPng,
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
    lastQuad = null;
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
    super.dispose();
  }
}
