import 'dart:typed_data';

import '../db/card_dao.dart';
import '../models/fab_card.dart';
import '../models/scan_debug_info.dart';
import '../vision/phash.dart';

/// The outcome of recognising a captured card.
class RecognitionResult {
  const RecognitionResult({
    required this.card,
    required this.matchedPrint,
    required this.distance,
    required this.arm,
    required this.debug,
    this.ocrTitle,
  });

  final FabCard card;
  final CardPrint matchedPrint;
  final int distance;
  final String arm;
  final String? ocrTitle;

  /// Diagnostics for the debug panel.
  final ScanDebugInfo debug;
}

/// Which print of a title-matched card the phash selected.
class _TitlePick {
  const _TitlePick(this.card, this.print, this.distance, this.phashArm);
  final FabCard card;
  final CardPrint print;

  /// Best phash Hamming distance among the candidate prints, or `1 << 30` when
  /// no phash signal was available (we then fell back to the canonical print).
  final int distance;

  /// The phash arm that produced [distance] ('art' / 'full'), or '' when none.
  final String phashArm;
}

/// Bridges the vision pipeline and the card database.
class CardRepository {
  CardRepository(this._dao, {this.minTitleConfidence = 60});

  final CardDao _dao;

  /// Minimum word-level OCR confidence (0..100) at which we trust the read
  /// title to identify the card. Above this the OCR title takes priority over
  /// pHash for *which card*; the pHash still picks the variant/pitch among the
  /// matched name's prints. The clean, deskewed title bar makes OCR reliable
  /// here, so this is worth doing.
  final double minTitleConfidence;

  int get cardCount => _dao.cachedPrintCount;

  /// Finds the best card for a set of captured hashes, loading its full set of
  /// variants. Returns null when nothing matches.
  ///
  /// Recognition has two arms:
  ///   * **title** — when [ocrTitle] is read with [ocrConfidence] at or above
  ///     [minTitleConfidence] and fuzzy-matches a card name, that name decides
  ///     the card and the phash only selects the variant among its prints.
  ///   * **phash** — otherwise, the perceptual-hash match across all prints
  ///     (the original path), gated by the Hamming thresholds.
  ///
  /// [detectorScore] and the captured PNGs are optional extras used only to
  /// populate the debug panel.
  Future<RecognitionResult?> recognize(
    ScanHashes hashes, {
    String? ocrTitle,
    double? ocrConfidence,
    double? detectorScore,
    String? detectSource,
    Uint8List? capturedCardPng,
    Uint8List? capturedArtPng,
    Uint8List? capturedTitleRawPng,
    Uint8List? capturedTitleOcrPng,
  }) async {
    // Title arm: trust a confidently-read title to name the card.
    if (ocrTitle != null &&
        ocrTitle.trim().isNotEmpty &&
        ocrConfidence != null &&
        ocrConfidence >= minTitleConfidence) {
      final titleCards = await _dao.matchByTitle(ocrTitle);
      final pick = _pickByPhash(titleCards, hashes);
      if (pick != null) {
        return _buildResult(
          card: pick.card,
          matchedPrint: pick.print,
          matchedArm: 'title',
          distance: pick.phashArm.isEmpty ? 0 : pick.distance,
          threshold: _thresholdFor(pick.phashArm),
          hashes: hashes,
          ocrTitle: ocrTitle,
          ocrConfidence: ocrConfidence,
          detectorScore: detectorScore,
          detectSource: detectSource,
          capturedCardPng: capturedCardPng,
          capturedArtPng: capturedArtPng,
          capturedTitleRawPng: capturedTitleRawPng,
          capturedTitleOcrPng: capturedTitleOcrPng,
          candidates: _candidatesFor(titleCards, hashes),
        );
      }
    }

    // pHash arm: match across every print, gated by the Hamming thresholds.
    final matches = await _dao.matchByPhash(hashes);
    if (matches.isEmpty) return null;
    final best = matches.first;
    final card = await _dao.getCardWithPrints(best.cardId);
    if (card == null || card.prints.isEmpty) return null;
    final matchedPrint = card.prints.firstWhere(
      (p) => p.id == best.printId,
      orElse: () => card.prints.first,
    );

    return _buildResult(
      card: card,
      matchedPrint: matchedPrint,
      matchedArm: best.arm,
      distance: best.distance,
      threshold: _thresholdFor(best.arm),
      hashes: hashes,
      ocrTitle: ocrTitle,
      ocrConfidence: ocrConfidence,
      detectorScore: detectorScore,
      detectSource: detectSource,
      capturedCardPng: capturedCardPng,
      capturedArtPng: capturedArtPng,
      capturedTitleRawPng: capturedTitleRawPng,
      capturedTitleOcrPng: capturedTitleOcrPng,
      candidates: matches
          .map((m) => ScanCandidate(
                faceId: m.printId,
                distance: m.distance,
                arm: m.arm,
              ))
          .toList(),
    );
  }

  RecognitionResult _buildResult({
    required FabCard card,
    required CardPrint matchedPrint,
    required String matchedArm,
    required int distance,
    required int threshold,
    required ScanHashes hashes,
    required List<ScanCandidate> candidates,
    String? ocrTitle,
    double? ocrConfidence,
    double? detectorScore,
    String? detectSource,
    Uint8List? capturedCardPng,
    Uint8List? capturedArtPng,
    Uint8List? capturedTitleRawPng,
    Uint8List? capturedTitleOcrPng,
  }) {
    final debug = ScanDebugInfo(
      matchedArm: matchedArm,
      distance: distance,
      threshold: threshold,
      detectSource: detectSource,
      detectorScore: detectorScore,
      ocrTitle: ocrTitle,
      ocrConfidence: ocrConfidence,
      queryArt: hashes.art,
      queryFull: hashes.full,
      matchedArtPhash: matchedPrint.imagePhash,
      matchedFullPhash: matchedPrint.imagePhashFull,
      capturedCardPng: capturedCardPng,
      capturedArtPng: capturedArtPng,
      capturedTitleRawPng: capturedTitleRawPng,
      capturedTitleOcrPng: capturedTitleOcrPng,
      candidates: candidates,
    );
    return RecognitionResult(
      card: card,
      matchedPrint: matchedPrint,
      distance: distance,
      arm: matchedArm,
      ocrTitle: ocrTitle,
      debug: debug,
    );
  }

  static int _thresholdFor(String arm) => switch (arm) {
        'full' => CardDao.fullThreshold,
        'art' => CardDao.artThreshold,
        _ => 0,
      };

  /// Among the prints of [cards], picks the one closest to [hashes] by phash
  /// (thresholds ignored — the title already named the card, so we only need
  /// the best variant). Falls back to the canonical print when there is no
  /// usable phash signal. Returns null only when [cards] has no prints.
  _TitlePick? _pickByPhash(List<FabCard> cards, ScanHashes hashes) {
    if (cards.isEmpty) return null;
    FabCard? bestCard;
    CardPrint? bestPrint;
    var bestDist = 1 << 30;
    var bestArm = '';
    for (final card in cards) {
      for (final print in card.prints) {
        void consider(int? probe, int? target, String arm) {
          if (probe == null || target == null) return;
          final d = PHash.hammingDistance(probe, target);
          if (d < bestDist) {
            bestDist = d;
            bestArm = arm;
            bestCard = card;
            bestPrint = print;
          }
        }

        consider(hashes.art, print.imagePhash, 'art');
        consider(hashes.full, print.imagePhashFull, 'full');
      }
    }
    if (bestPrint != null) {
      return _TitlePick(bestCard!, bestPrint!, bestDist, bestArm);
    }
    // No phash to compare against — keep the right name, show its canonical
    // print (pitch can't be disambiguated without a phash or pitch colour).
    final canonical = cards.first.canonicalPrint;
    if (canonical == null) return null;
    return _TitlePick(cards.first, canonical, 1 << 30, '');
  }

  /// Ranked debug candidates: the closest prints among the title-matched cards.
  List<ScanCandidate> _candidatesFor(List<FabCard> cards, ScanHashes hashes) {
    final out = <ScanCandidate>[];
    for (final card in cards) {
      for (final print in card.prints) {
        var d = 1 << 30;
        var arm = '';
        void consider(int? probe, int? target, String a) {
          if (probe == null || target == null) return;
          final dd = PHash.hammingDistance(probe, target);
          if (dd < d) {
            d = dd;
            arm = a;
          }
        }

        consider(hashes.art, print.imagePhash, 'art');
        consider(hashes.full, print.imagePhashFull, 'full');
        if (arm.isNotEmpty) {
          out.add(ScanCandidate(faceId: print.faceId, distance: d, arm: arm));
        }
      }
    }
    out.sort((a, b) => a.distance.compareTo(b.distance));
    return out.take(5).toList();
  }

  /// Diagnostics: the globally closest prints ignoring thresholds.
  Future<List<PhashMatch>> diagnoseClosest(ScanHashes hashes) =>
      _dao.diagnoseClosest(hashes);

  Future<FabCard?> cardById(String cardId) => _dao.getCardWithPrints(cardId);

  Future<List<FabCard>> searchByName(String query) => _dao.searchByName(query);
}
