import 'dart:typed_data';

/// Diagnostic information about how a card was recognised, surfaced in the
/// debug panel (mirrors the "Detection signals" block in fab-tabletop).
class ScanDebugInfo {
  const ScanDebugInfo({
    required this.matchedArm,
    required this.distance,
    required this.threshold,
    this.detectSource,
    this.detectorScore,
    this.ocrTitle,
    this.ocrConfidence,
    this.detectedPitch,
    this.pitchConfidence,
    this.queryArt,
    this.queryFull,
    this.matchedArtPhash,
    this.matchedFullPhash,
    this.capturedCardPng,
    this.capturedArtPng,
    this.capturedTitleRawPng,
    this.capturedTitleOcrPng,
    this.candidates = const [],
  });

  /// Which pHash arm produced the match — the "detect method"
  /// (e.g. "art", "full").
  final String matchedArm;

  /// Hamming distance of the winning arm, and the threshold it had to beat.
  final int distance;
  final int threshold;

  /// How the card was located: "contour" (Canny + deskew) or "guide".
  final String? detectSource;

  /// OpenCV detector confidence (0..1) for the captured frame.
  final double? detectorScore;

  /// Title text read by Tesseract (may be empty/null).
  final String? ocrTitle;

  /// Word-level mean OCR confidence (0..100) for [ocrTitle].
  final double? ocrConfidence;

  /// Pitch detected from the colour strip (1 = red, 2 = yellow, 3 = blue), or
  /// null when no hue won by a clear margin (non-pitch cards, uncertain
  /// lighting). Used by the title arm to disambiguate cards that share a name
  /// across pitches (e.g. *Absorb in Aether* 1/2/3).
  final int? detectedPitch;

  /// Winning hue's share of the voting pixels (0..1).
  final double? pitchConfidence;

  /// Hashes computed live from the capture.
  final int? queryArt;
  final int? queryFull;

  /// Hashes stored in the DB for the matched print.
  final int? matchedArtPhash;
  final int? matchedFullPhash;

  /// PNG of the deskewed card OpenCV produced (what the `full` arm hashed).
  final Uint8List? capturedCardPng;

  /// PNG of the art crop (the `art` arm).
  final Uint8List? capturedArtPng;

  /// Title-bar crops: the raw colour region, and the grayscaled/upscaled image
  /// actually fed to Tesseract.
  final Uint8List? capturedTitleRawPng;
  final Uint8List? capturedTitleOcrPng;

  /// Other near matches, closest first.
  final List<ScanCandidate> candidates;

  bool get usedOcr => ocrTitle != null && ocrTitle!.isNotEmpty;
}

/// One ranked candidate from the pHash lookup.
class ScanCandidate {
  const ScanCandidate({
    required this.faceId,
    required this.distance,
    required this.arm,
  });

  final String faceId;
  final int distance;
  final String arm;
}
