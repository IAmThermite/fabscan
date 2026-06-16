import 'package:fabscan/src/db/price_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late PriceStore store;

  setUp(() async {
    store = await PriceStore.openInMemory();
  });

  tearDown(() async {
    await store.close();
  });

  List<PriceQuoteRow> rows(String printId) => [
        PriceQuoteRow(
            printId: printId,
            source: 'MinMaxGames',
            price: 12.5,
            currency: 'AUD',
            url: 'https://mmg/x'),
        PriceQuoteRow(
            printId: printId,
            source: 'TCGplayer',
            price: 8.99,
            currency: 'USD',
            url: 'https://tcg/y',
            inStock: false),
      ];

  test('empty store is stale and has no timestamps', () async {
    expect(await store.isStale(const Duration(hours: 24)), true);
    expect(await store.fetchedAt(), isNull);
    expect(await store.datasetGeneratedAt(), isNull);
    expect(await store.quotesForPrint('whatever'), isEmpty);
  });

  test('defaults the display currency to NZD and persists changes', () async {
    expect(await store.displayCurrency(), 'NZD');
    await store.setDisplayCurrency('AUD');
    expect(await store.displayCurrency(), 'AUD');
  });

  test('replaceAll round-trips rows, fx and timestamps', () async {
    await store.replaceAll(
      generatedAt: '2026-06-17T03:00:00Z',
      datasetSchemaVersion: 1,
      fxBase: 'USD',
      fxRates: {'USD': 1, 'AUD': 1.52},
      rows: rows('print-1'),
    );

    final q = await store.quotesForPrint('print-1');
    expect(q.length, 2);
    expect(q.map((r) => r.source).toSet(), {'MinMaxGames', 'TCGplayer'});

    expect(await store.datasetGeneratedAt(),
        DateTime.parse('2026-06-17T03:00:00Z'));
    expect(await store.fxBase(), 'USD');
    expect((await store.fxRates())['AUD'], 1.52);
    expect(await store.isStale(const Duration(hours: 24)), false);
  });

  test('replaceAll is atomic — old rows are gone', () async {
    await store.replaceAll(
      generatedAt: '2026-06-16T03:00:00Z',
      datasetSchemaVersion: 1,
      rows: rows('old-print'),
    );
    await store.replaceAll(
      generatedAt: '2026-06-17T03:00:00Z',
      datasetSchemaVersion: 1,
      rows: rows('new-print'),
    );
    expect(await store.quotesForPrint('old-print'), isEmpty);
    expect(await store.quotesForPrint('new-print'), hasLength(2));
  });

  test('replaceAll preserves the user display-currency preference', () async {
    await store.setDisplayCurrency('EUR');
    await store.replaceAll(
      generatedAt: '2026-06-17T03:00:00Z',
      datasetSchemaVersion: 1,
      rows: rows('print-1'),
    );
    expect(await store.displayCurrency(), 'EUR');
  });

  test('touchFetchedAt clears staleness only once populated', () async {
    await store.touchFetchedAt();
    expect(await store.fetchedAt(), isNull, reason: 'no-op while empty');

    await store.replaceAll(
      generatedAt: '2026-06-17T03:00:00Z',
      datasetSchemaVersion: 1,
      rows: rows('print-1'),
    );
    await store.touchFetchedAt();
    expect(await store.isStale(const Duration(hours: 24)), false);
  });
}
