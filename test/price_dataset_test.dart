import 'package:fabscan/src/pricing/price_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parsePriceDataset', () {
    test('parses the short-key shape including fx', () {
      final ds = parsePriceDataset({
        'schema_version': 1,
        'generated_at': '2026-06-17T03:00:00Z',
        'fx': {
          'base': 'USD',
          'rates': {'USD': 1, 'AUD': 1.52, 'NZD': 1.64},
        },
        'prints': {
          'print-1': {
            'MinMaxGames': {'p': 12.5, 'c': 'AUD', 'u': 'https://x', 's': true},
            'TCGplayer': {'p': 8.99, 'c': 'USD', 'u': 'https://y', 's': false},
          },
        },
      });
      expect(ds, isNotNull);
      expect(ds!.generatedAt, '2026-06-17T03:00:00Z');
      expect(ds.fxBase, 'USD');
      expect(ds.fxRates!['AUD'], 1.52);
      expect(ds.rows.length, 2);
      final mmg = ds.rows.firstWhere((r) => r.source == 'MinMaxGames');
      expect(mmg.printId, 'print-1');
      expect(mmg.price, 12.5);
      expect(mmg.currency, 'AUD');
      expect(mmg.inStock, true);
      final tcg = ds.rows.firstWhere((r) => r.source == 'TCGplayer');
      expect(tcg.inStock, false);
    });

    test('rejects a too-new schema version', () {
      expect(
        parsePriceDataset({
          'schema_version': supportedPriceSchemaVersion + 1,
          'generated_at': '2026-06-17T03:00:00Z',
          'prints': const {},
        }),
        isNull,
      );
    });

    test('rejects when generated_at is missing', () {
      expect(parsePriceDataset({'schema_version': 1, 'prints': const {}}), isNull);
    });

    test('tolerates missing fields and malformed entries', () {
      final ds = parsePriceDataset({
        'schema_version': 1,
        'generated_at': '2026-06-17T03:00:00Z',
        'prints': {
          'print-1': {
            'MinMaxGames': {'c': 'AUD'}, // no price
            'Bogus': 'not-a-map',
          },
          'print-2': 'also-not-a-map',
        },
      });
      expect(ds, isNotNull);
      expect(ds!.rows.length, 1);
      expect(ds.rows.single.price, isNull);
      expect(ds.fxRates, isNull);
    });

    test('parsePriceDatasetJson returns null on invalid json', () {
      expect(parsePriceDatasetJson('{not json'), isNull);
      expect(parsePriceDatasetJson('[]'), isNull);
    });
  });
}
