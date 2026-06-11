import 'package:sqflite/sqflite.dart';

import '../data/title_matcher.dart';
import '../models/fab_card.dart';
import '../vision/phash.dart';

/// The set of perceptual hashes computed from a single captured frame.
///
/// Multi-arm matching like the reference scanner: the upright art crop ([art])
/// and the whole-card hash ([full]).
class ScanHashes {
  const ScanHashes({
    this.art,
    this.full,
  });

  final int? art;
  final int? full;
}

/// One ranked candidate from a phash lookup.
class PhashMatch {
  const PhashMatch({
    required this.printId,
    required this.cardId,
    required this.distance,
    required this.arm,
  });

  final String printId;
  final String cardId;
  final int distance;

  /// Which arm produced the best distance ("art" or "full").
  final String arm;
}

/// Cached, comparable hashes for a single print row.
class _PrintHashes {
  const _PrintHashes(this.printId, this.cardId, this.art, this.full);
  final String printId;
  final String cardId;
  final int? art;
  final int? full;
}

/// A distinct card name: [stored] is the DB `normalized_name` (used for the
/// lookup query), [comparable] is the further-normalized form we fuzzy-match
/// the OCR text against.
class _CardName {
  const _CardName(this.stored, this.comparable);
  final String stored;
  final String comparable;
}

/// Read access to the bundled card database: phash matching and card loading.
class CardDao {
  CardDao(this.db);

  final Database db;

  // Max Hamming distance to accept a match per arm (reference uses 15 / 8).
  // Lower = stricter (fewer false positives, but near-misses get rejected).
  static const int artThreshold = 15;
  static const int fullThreshold = 8;

  // Minimum normalized similarity for an OCR title to be accepted as a card
  // name (see [matchByTitle]). The confidence gate lives in CardRepository.
  static const double minTitleSimilarity = 0.72;

  List<_PrintHashes>? _cache;
  List<_CardName>? _nameCache;

  /// Loads (once) every print's hashes into memory. The full set for FAB is a
  /// few thousand rows, so a linear scan per capture is cheap.
  Future<void> _ensureCache() async {
    if (_cache != null) return;
    final rows = await db.query('card_prints', columns: [
      'id',
      'card_id',
      'image_phash',
      'image_phash_full',
    ]);
    _cache = rows
        .map((r) => _PrintHashes(
              r['id'] as String,
              r['card_id'] as String,
              r['image_phash'] as int?,
              r['image_phash_full'] as int?,
            ))
        .toList(growable: false);
  }

  /// Ranks prints by best Hamming distance across all qualifying arms.
  /// Returns at most [limit] matches, closest first.
  Future<List<PhashMatch>> matchByPhash(ScanHashes q, {int limit = 5}) async {
    await _ensureCache();
    final matches = <PhashMatch>[];

    for (final ph in _cache!) {
      var best = 1 << 30;
      var bestArm = '';

      void consider(int? probe, int? target, int threshold, String arm) {
        if (probe == null || target == null) return;
        final d = PHash.hammingDistance(probe, target);
        if (d <= threshold && d < best) {
          best = d;
          bestArm = arm;
        }
      }

      consider(q.art, ph.art, artThreshold, 'art');
      consider(q.full, ph.full, fullThreshold, 'full');

      if (bestArm.isNotEmpty) {
        matches.add(PhashMatch(
          printId: ph.printId,
          cardId: ph.cardId,
          distance: best,
          arm: bestArm,
        ));
      }
    }

    matches.sort((a, b) => a.distance.compareTo(b.distance));
    return matches.take(limit).toList();
  }

  /// Like [matchByPhash] but IGNORES the distance thresholds — returns the
  /// globally closest prints regardless of how far off they are. Used purely
  /// for diagnostics (e.g. logging near-misses to understand poor matching).
  Future<List<PhashMatch>> diagnoseClosest(ScanHashes q, {int limit = 5}) async {
    await _ensureCache();
    final matches = <PhashMatch>[];
    for (final ph in _cache!) {
      var best = 1 << 30;
      var bestArm = '';
      void consider(int? probe, int? target, String arm) {
        if (probe == null || target == null) return;
        final d = PHash.hammingDistance(probe, target);
        if (d < best) {
          best = d;
          bestArm = arm;
        }
      }

      consider(q.art, ph.art, 'art');
      consider(q.full, ph.full, 'full');
      if (bestArm.isNotEmpty) {
        matches.add(PhashMatch(
          printId: ph.printId,
          cardId: ph.cardId,
          distance: best,
          arm: bestArm,
        ));
      }
    }
    matches.sort((a, b) => a.distance.compareTo(b.distance));
    return matches.take(limit).toList();
  }

  /// Loads a card together with all of its prints (variants).
  Future<FabCard?> getCardWithPrints(String cardId) async {
    final cardRows =
        await db.query('cards', where: 'id = ?', whereArgs: [cardId], limit: 1);
    if (cardRows.isEmpty) return null;

    final printRows = await db.query(
      'card_prints',
      where: 'card_id = ?',
      whereArgs: [cardId],
      orderBy: 'is_canonical DESC, set_code ASC, layout_position ASC',
    );
    final prints = printRows.map(CardPrint.fromMap).toList();
    return FabCard.fromMap(cardRows.first, prints: prints);
  }

  Future<CardPrint?> getPrint(String printId) async {
    final rows = await db.query('card_prints',
        where: 'id = ?', whereArgs: [printId], limit: 1);
    if (rows.isEmpty) return null;
    return CardPrint.fromMap(rows.first);
  }

  /// Loads (once) the distinct card names for fuzzy title matching.
  Future<void> _ensureNameCache() async {
    if (_nameCache != null) return;
    final rows = await db.query(
      'cards',
      columns: ['normalized_name'],
      distinct: true,
      where: 'normalized_name IS NOT NULL',
    );
    _nameCache = rows
        .map((r) => r['normalized_name'] as String)
        .map((n) => _CardName(n, normalizeTitle(n)))
        .toList(growable: false);
  }

  /// Resolves an OCR title to the matching card(s) by fuzzy name similarity.
  ///
  /// Returns every card sharing the best-matching name (each with its prints
  /// loaded) — a single name can map to several cards (one per pitch), which
  /// the caller disambiguates with the phash. Returns an empty list when no
  /// name clears [minSimilarity].
  Future<List<FabCard>> matchByTitle(
    String ocrText, {
    double minSimilarity = minTitleSimilarity,
  }) async {
    await _ensureNameCache();
    final query = normalizeTitle(ocrText);
    if (query.isEmpty) return [];

    var bestSim = 0.0;
    String? bestComparable;
    for (final name in _nameCache!) {
      final sim = titleSimilarity(query, name.comparable);
      if (sim > bestSim) {
        bestSim = sim;
        bestComparable = name.comparable;
      }
    }
    if (bestComparable == null || bestSim < minSimilarity) return [];

    // Every stored name that reduces to the winning comparable form.
    final stored = _nameCache!
        .where((n) => n.comparable == bestComparable)
        .map((n) => n.stored)
        .toList();
    final placeholders = List.filled(stored.length, '?').join(',');
    final rows = await db.query(
      'cards',
      where: 'normalized_name IN ($placeholders)',
      whereArgs: stored,
      orderBy: 'pitch ASC',
    );

    final cards = <FabCard>[];
    for (final row in rows) {
      final card = await getCardWithPrints(row['id'] as String);
      if (card != null) cards.add(card);
    }
    return cards;
  }

  /// All cards that share [name] (one per pitch), each with its prints loaded,
  /// ordered by pitch. Used to offer the pitch variations of a recognised card.
  Future<List<FabCard>> cardsByName(String name) async {
    final rows = await db.query(
      'cards',
      where: 'normalized_name = ?',
      whereArgs: [name.toLowerCase()],
      orderBy: 'pitch ASC',
    );
    final cards = <FabCard>[];
    for (final row in rows) {
      final card = await getCardWithPrints(row['id'] as String);
      if (card != null) cards.add(card);
    }
    return cards;
  }

  /// Free-text fallback search by card name (used when OCR succeeds but the
  /// phash is ambiguous).
  Future<List<FabCard>> searchByName(String query, {int limit = 10}) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return [];
    final rows = await db.query(
      'cards',
      where: 'normalized_name LIKE ?',
      whereArgs: ['%$normalized%'],
      limit: limit,
    );
    return rows.map((r) => FabCard.fromMap(r)).toList();
  }

  int get cachedPrintCount => _cache?.length ?? 0;
}
