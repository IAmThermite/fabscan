import 'fab_card.dart';

/// One pitch option for a scanned card name: the pitch value (1/2/3), the
/// [FabCard] that carries it (a name maps to one card per pitch), and the
/// representative [CardPrint] to show for it within the chosen set.
class PitchVariant {
  const PitchVariant({
    required this.pitch,
    required this.card,
    required this.print,
  });

  final int pitch;
  final FabCard card;
  final CardPrint print;
}

/// The pitch variations to offer for a recognised card, all drawn from a single
/// [setCode] so the alternatives are visually consistent. Empty when the card
/// has no set in which two or more pitches were printed together.
class PitchVariantSet {
  const PitchVariantSet({required this.setCode, required this.variants});

  /// The set the [variants] were drawn from, or null when there are none.
  final String? setCode;

  /// One entry per available pitch, sorted ascending (red 1, yellow 2, blue 3).
  final List<PitchVariant> variants;

  static const PitchVariantSet empty =
      PitchVariantSet(setCode: null, variants: []);

  /// True when there is more than one pitch to flick between.
  bool get hasMultiple => variants.length > 1;

  PitchVariant? byPitch(int pitch) {
    for (final v in variants) {
      if (v.pitch == pitch) return v;
    }
    return null;
  }
}

/// Picks the set of pitch variations to show for a recognised card.
///
/// [namedCards] are all the cards sharing the recognised name (one per pitch).
/// We prefer the variations that live in the **same set** as the scanned print
/// ([matchedPrint]); when that set doesn't hold two or more pitches we fall back
/// to the first set (in encounter order) that does. The matched pitch keeps the
/// exact scanned print when it belongs to the chosen set, so the view doesn't
/// jump to a different printing on load.
PitchVariantSet resolvePitchVariants({
  required List<FabCard> namedCards,
  required FabCard matchedCard,
  required CardPrint matchedPrint,
}) {
  // setCode -> (pitch -> first-seen representative), preserving set encounter
  // order so the fallback is deterministic.
  final bySet = <String, Map<int, PitchVariant>>{};
  final setOrder = <String>[];
  for (final card in namedCards) {
    final pitch = card.pitch;
    if (pitch == null) continue; // non-pitch cards (weapons, equipment) don't apply
    for (final print in card.prints) {
      final set = print.setCode;
      if (set == null) continue;
      final byPitch = bySet.putIfAbsent(set, () {
        setOrder.add(set);
        return <int, PitchVariant>{};
      });
      byPitch.putIfAbsent(
        pitch,
        () => PitchVariant(pitch: pitch, card: card, print: print),
      );
    }
  }

  final matchedSet = matchedPrint.setCode;
  String? chosen;
  if (matchedSet != null && (bySet[matchedSet]?.length ?? 0) > 1) {
    chosen = matchedSet;
  } else {
    for (final set in setOrder) {
      if (bySet[set]!.length > 1) {
        chosen = set;
        break;
      }
    }
  }
  if (chosen == null) return PitchVariantSet.empty;

  final byPitch = Map<int, PitchVariant>.of(bySet[chosen]!);
  // Show the exact scanned print for the matched pitch when it's in this set.
  final mp = matchedCard.pitch;
  if (mp != null && chosen == matchedSet && byPitch.containsKey(mp)) {
    byPitch[mp] =
        PitchVariant(pitch: mp, card: matchedCard, print: matchedPrint);
  }
  final variants = byPitch.values.toList()
    ..sort((a, b) => a.pitch.compareTo(b.pitch));
  return PitchVariantSet(setCode: chosen, variants: variants);
}
