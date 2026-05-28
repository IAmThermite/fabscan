import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Reads a card's title using Tesseract.
///
/// Mirrors the reference scanner: crop the title bar (y=10%, h=4%, inset 19%
/// each side), upscale and grayscale it, then run Tesseract in single-line
/// mode (PSM 7) restricted to the characters that appear in card titles.
///
/// Requires `assets/tessdata/eng.traineddata` and `assets/tessdata_config.json`
/// to be bundled (declared in pubspec.yaml).

/// Result of a title OCR pass: the recognised [text], a [confidence] score and
/// the title crop images used (for the debug panel).
class OcrResult {
  const OcrResult({
    required this.text,
    this.confidence = 0,
    this.rawPng,
    this.processedPng,
  });

  final String text;

  /// Word-level mean confidence in 0..100 (page-level confidence is unreliable
  /// in single-line PSM 7, so we average the per-word `x_wconf` values from the
  /// hOCR output, mirroring the reference scanner). 0 when nothing was read or
  /// confidences were unavailable.
  final double confidence;

  /// The raw colour title crop.
  final Uint8List? rawPng;

  /// The grayscaled, upscaled image actually fed to Tesseract.
  final Uint8List? processedPng;
}

class OcrService {
  // Title-bar crop region, as ratios of the upright card (tune these to aim
  // the OCR box). titleY = distance from the top; titleH = strip height;
  // titleXInset = margin trimmed from each side. Lower titleY = higher up.
  static const double titleY = 0.01;
  static const double titleH = 0.08;
  static const double titleXInset = 0.16;

  static const Map<String, dynamic> _args = {
    // PSM 7: treat the image as a single text line.
    'psm': '7',
    'preserve_interword_spaces': '1',
    'tessedit_char_whitelist':
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 '-,",
  };

  /// Reads the title from an upright card RGB buffer. Always returns the title
  /// crop images (for the debug panel), and the cleaned text if legible.
  Future<OcrResult> readTitle(Uint8List cardRgb, int cardW, int cardH) async {
    final x = (titleXInset * cardW).round();
    final y = (titleY * cardH).round();
    final w = ((1 - 2 * titleXInset) * cardW).round();
    final h = (titleH * cardH).round();
    if (w <= 0 || h <= 0) return const OcrResult(text: '');

    final full = img.Image.fromBytes(
      width: cardW,
      height: cardH,
      bytes: cardRgb.buffer,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );
    final rawCrop = img.copyCrop(full, x: x, y: y, width: w, height: h);

    // Preprocess for OCR: grayscale, then upscale 3x (nearest neighbour, like
    // the reference) so small title text is easier for Tesseract.
    var processed = img.grayscale(img.Image.from(rawCrop));
    processed = img.copyResize(
      processed,
      width: processed.width * 3,
      height: processed.height * 3,
      interpolation: img.Interpolation.nearest,
    );

    final rawPng = img.encodePng(rawCrop);
    final processedPng = img.encodePng(processed);

    final path = await _writeTemp(processedPng);
    var text = '';
    var confidence = 0.0;
    try {
      // hOCR carries per-word confidence (`x_wconf`); plain extractText does
      // not. Parse it for both the text and a word-level mean confidence.
      final hocr = await FlutterTesseractOcr.extractHocr(
        path,
        language: 'eng',
        args: _args,
      );
      final parsed = parseHocr(hocr);
      text = parsed.text;
      confidence = parsed.confidence;
    } catch (_) {
      // tessdata missing or native failure — degrade gracefully (keep images).
    } finally {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    return OcrResult(
      text: text,
      confidence: confidence,
      rawPng: rawPng,
      processedPng: processedPng,
    );
  }

  // Matches a single hOCR word span, capturing its `x_wconf` value and inner
  // markup. Quote-agnostic (Tesseract emits single quotes, but be lenient).
  static final RegExp _wordRe = RegExp(
    r'class=.ocrx_word.[^>]*?x_wconf (\d+)[^>]*>(.*?)</span>',
    dotAll: true,
  );
  static final RegExp _tagRe = RegExp(r'<[^>]*>');
  static final RegExp _letterRe = RegExp(r'[A-Za-z]');

  /// Extracts the recognised text and the mean confidence of letter-bearing
  /// words from an hOCR document.
  @visibleForTesting
  static ({String text, double confidence}) parseHocr(String hocr) {
    final words = <String>[];
    var sum = 0.0;
    var n = 0;
    for (final m in _wordRe.allMatches(hocr)) {
      final conf = double.tryParse(m.group(1) ?? '') ?? 0;
      final word = _unescape(m.group(2)?.replaceAll(_tagRe, '') ?? '').trim();
      if (word.isEmpty) continue;
      words.add(word);
      // Stray punctuation-only "words" skew the mean — only count real words.
      if (_letterRe.hasMatch(word)) {
        sum += conf;
        n++;
      }
    }
    return (text: _clean(words.join(' ')), confidence: n > 0 ? sum / n : 0.0);
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");

  static String _clean(String raw) =>
      raw.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<String> _writeTemp(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final path = p.join(
        dir.path, 'ocr_${DateTime.now().microsecondsSinceEpoch}.png');
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }
}
