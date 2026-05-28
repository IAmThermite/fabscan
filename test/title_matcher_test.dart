import 'package:fabscan/src/data/title_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeTitle', () {
    test('lower-cases and strips punctuation to spaces', () {
      expect(normalizeTitle('Rhinar, Reckless Rampage'),
          'rhinar reckless rampage');
      expect(normalizeTitle("Enlightened Strike"), 'enlightened strike');
      expect(normalizeTitle('  Spreading   Plague!! '), 'spreading plague');
    });

    test('keeps digits', () {
      expect(normalizeTitle('10,000 Year Reunion'), '10 000 year reunion');
    });

    test('empty / punctuation-only normalizes to empty', () {
      expect(normalizeTitle('   '), '');
      expect(normalizeTitle('!!!'), '');
    });
  });

  group('levenshtein', () {
    test('identical strings have distance 0', () {
      expect(levenshtein('command', 'command'), 0);
    });

    test('counts single-character edits', () {
      expect(levenshtein('rhinar', 'rhlnar'), 1); // substitution
      expect(levenshtein('strike', 'strikes'), 1); // insertion
    });
  });

  group('titleSimilarity', () {
    test('exact normalized match scores 1.0', () {
      final a = normalizeTitle('Command and Conquer');
      final b = normalizeTitle('command and conquer');
      expect(titleSimilarity(a, b), 1.0);
    });

    test('tolerates a one-character OCR slip', () {
      final stored = normalizeTitle('Rhinar, Reckless Rampage');
      final ocr = normalizeTitle('Rhlnar Reckless Rampage'); // i -> l
      expect(titleSimilarity(ocr, stored), greaterThan(0.9));
    });

    test('boosts when OCR dropped a trailing word (containment)', () {
      final stored = normalizeTitle('Command and Conquer');
      final ocr = normalizeTitle('Command and'); // banner clipped
      expect(titleSimilarity(ocr, stored), greaterThan(0.5));
    });

    test('different cards score below the accept threshold', () {
      final a = normalizeTitle('Enlightened Strike');
      final b = normalizeTitle('Spreading Plague');
      expect(titleSimilarity(a, b), lessThan(0.72));
    });

    test('empty input scores 0', () {
      expect(titleSimilarity('', 'anything'), 0);
    });
  });
}
