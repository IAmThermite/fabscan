import 'package:fabscan/src/models/fab_card.dart';
import 'package:fabscan/src/models/pitch_variants.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a pitch-card with one print per given set code.
FabCard _card(int pitch, List<String> sets) => FabCard(
      id: 'card-p$pitch',
      name: 'Absorb in Aether',
      pitch: pitch,
      prints: [
        for (final s in sets)
          CardPrint(
            id: '$s-p$pitch',
            cardId: 'card-p$pitch',
            faceId: '$s-p$pitch',
            setCode: s,
          ),
      ],
    );

void main() {
  group('resolvePitchVariants', () {
    test('prefers the scanned set when it holds multiple pitches', () {
      final cards = [
        _card(1, ['WTR']),
        _card(2, ['WTR']),
        _card(3, ['WTR']),
      ];
      final matched = cards[1]; // pitch 2
      final matchedPrint = matched.prints.single; // WTR-p2

      final result = resolvePitchVariants(
        namedCards: cards,
        matchedCard: matched,
        matchedPrint: matchedPrint,
      );

      expect(result.setCode, 'WTR');
      expect(result.variants.map((v) => v.pitch), [1, 2, 3]);
      // Matched pitch keeps the exact scanned print.
      expect(result.byPitch(2)!.print.id, matchedPrint.id);
    });

    test('falls back to the first set that has multiple pitches', () {
      // The scanned set (PROMO) only carries pitch 2; EVO carries 1 and 3.
      final cards = [
        _card(1, ['EVO']),
        _card(2, ['PROMO', 'EVO']),
        _card(3, ['EVO']),
      ];
      final matched = cards[1]; // pitch 2
      final matchedPrint =
          matched.prints.firstWhere((p) => p.setCode == 'PROMO');

      final result = resolvePitchVariants(
        namedCards: cards,
        matchedCard: matched,
        matchedPrint: matchedPrint,
      );

      expect(result.setCode, 'EVO');
      expect(result.variants.map((v) => v.pitch), [1, 2, 3]);
      // Pitch 2 in EVO is the EVO print, not the scanned PROMO one.
      expect(result.byPitch(2)!.print.setCode, 'EVO');
    });

    test('returns empty when no set has more than one pitch', () {
      final cards = [
        _card(1, ['WTR']),
        _card(2, ['ARC']),
      ];
      final matched = cards[0];
      final result = resolvePitchVariants(
        namedCards: cards,
        matchedCard: matched,
        matchedPrint: matched.prints.single,
      );

      expect(result.hasMultiple, isFalse);
      expect(result.variants, isEmpty);
      expect(result.setCode, isNull);
    });

    test('ignores non-pitch cards sharing the name', () {
      final cards = [
        _card(1, ['WTR']),
        FabCard(
          id: 'weapon',
          name: 'Absorb in Aether',
          pitch: null,
          prints: [
            const CardPrint(
              id: 'WTR-w',
              cardId: 'weapon',
              faceId: 'WTR-w',
              setCode: 'WTR',
            ),
          ],
        ),
      ];
      final matched = cards[0];
      final result = resolvePitchVariants(
        namedCards: cards,
        matchedCard: matched,
        matchedPrint: matched.prints.single,
      );

      // Only one real pitch — no selector.
      expect(result.hasMultiple, isFalse);
    });
  });
}
