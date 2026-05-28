// Pure-Dart fuzzy string matching for the OCR title arm. Kept free of any
// Flutter/DB imports so it can be unit-tested in isolation and reused by both
// the live scanner and tooling.
//
// FAB card titles are short and OCR (against the clean, deskewed title bar)
// is reliable, so a normalized Levenshtein ratio with a containment boost is
// enough to resolve the card name without a heavier fuzzy index.
import 'dart:math' as math;

final RegExp _nonAlnum = RegExp(r'[^a-z0-9]+');
final RegExp _spaces = RegExp(r'\s+');

/// Lower-cases [s], collapses every run of non-alphanumeric characters to a
/// single space and trims. Applied to BOTH the OCR text and the stored card
/// name so punctuation differences (commas, apostrophes, hyphens) and OCR
/// whitelist artifacts don't matter — e.g. "Rhinar, Reckless Rampage" and a
/// raw OCR "rhinar reckless rampage" normalize to the same string.
String normalizeTitle(String s) =>
    s.toLowerCase().replaceAll(_nonAlnum, ' ').replaceAll(_spaces, ' ').trim();

/// Levenshtein edit distance between [a] and [b] (two-row DP, O(a·b) time,
/// O(b) space). Card names are short, so this is cheap even across the whole
/// name list.
int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var prev = List<int>.generate(b.length + 1, (i) => i, growable: false);
  var curr = List<int>.filled(b.length + 1, 0);
  for (var i = 0; i < a.length; i++) {
    curr[0] = i + 1;
    final ca = a.codeUnitAt(i);
    for (var j = 0; j < b.length; j++) {
      final cost = ca == b.codeUnitAt(j) ? 0 : 1;
      curr[j + 1] = math.min(
        math.min(curr[j] + 1, prev[j + 1] + 1),
        prev[j] + cost,
      );
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[b.length];
}

/// Similarity in 0..1 between two already-[normalizeTitle]d strings.
///
/// Combines a normalized edit-distance ratio with a containment ratio: if one
/// string is a substring of the other (the title bar OCR dropped or gained a
/// trailing word) the score is at least the length overlap. Higher is better.
double titleSimilarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;

  final maxLen = math.max(a.length, b.length);
  final ratio = 1 - levenshtein(a, b) / maxLen;

  var contain = 0.0;
  if (a.contains(b) || b.contains(a)) {
    contain = math.min(a.length, b.length) / maxLen;
  }
  return math.max(ratio, contain);
}
