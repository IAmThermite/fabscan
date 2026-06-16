import 'package:fabscan/src/db/price_store.dart';
import 'package:fabscan/src/models/fab_card.dart';
import 'package:fabscan/src/pricing/pricing_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late PriceStore store;
  late PricingService pricing;

  const card = FabCard(id: 'c1', name: 'Rhinar');
  const print = CardPrint(
    id: 'print-1',
    cardId: 'c1',
    faceId: 'MST001',
    setCode: 'MST',
    tcgplayerUrl: 'https://www.tcgplayer.com/product/551703',
  );

  setUp(() async {
    store = await PriceStore.openInMemory();
    pricing = PricingService(store: store);
  });

  tearDown(() async => store.close());

  test('configured source names match the scraper contract', () {
    expect(
      pricing.sources.map((s) => s.name).toSet(),
      {'MinMaxGames', 'Fluke & Box', 'TCGplayer', 'Cardmarket'},
    );
  });

  test('empty store → one link-out per source, no prices', () async {
    final result = await pricing.quotesFor(card, print);
    expect(result.sources, hasLength(4));
    expect(result.generatedAt, isNull);
    for (final s in result.sources) {
      expect(s.quotes, hasLength(1));
      expect(s.quotes.single.isLinkOnly, true);
    }
    // TCGplayer deep-links to the stored product page.
    final tcg = result.sources.firstWhere((s) => s.source.name == 'TCGplayer');
    expect(tcg.quotes.single.url, contains('/product/551703'));
  });

  test('converts a stored price to the display currency (NZD default)', () async {
    await store.replaceAll(
      generatedAt: '2026-06-17T03:00:00Z',
      datasetSchemaVersion: 1,
      fxBase: 'USD',
      fxRates: {'USD': 1.0, 'AUD': 1.5, 'NZD': 1.6},
      rows: const [
        PriceQuoteRow(
            printId: 'print-1',
            source: 'MinMaxGames',
            price: 15,
            currency: 'AUD',
            url: 'https://mmg/x'),
      ],
    );

    final result = await pricing.quotesFor(card, print);
    expect(result.displayCurrency, 'NZD');
    final mmg = result.sources.firstWhere((s) => s.source.name == 'MinMaxGames');
    final q = mmg.quotes.single;
    // 15 AUD -> USD 10 -> NZD 16.
    expect(q.price, closeTo(16, 1e-9));
    expect(q.currency, 'NZD');
    expect(q.converted, true);
    expect(q.originalPrice, 15);
    expect(q.originalCurrency, 'AUD');
    expect(q.url, 'https://mmg/x');

    // Other sources still link out.
    final cm = result.sources.firstWhere((s) => s.source.name == 'Cardmarket');
    expect(cm.quotes.single.isLinkOnly, true);
  });

  test('falls back to the original currency when a rate is missing', () async {
    await store.setDisplayCurrency('GBP'); // no GBP rate shipped below
    await store.replaceAll(
      generatedAt: '2026-06-17T03:00:00Z',
      datasetSchemaVersion: 1,
      fxBase: 'USD',
      fxRates: {'USD': 1.0, 'AUD': 1.5},
      rows: const [
        PriceQuoteRow(
            printId: 'print-1', source: 'MinMaxGames', price: 15, currency: 'AUD'),
      ],
    );

    final result = await pricing.quotesFor(card, print);
    final mmg = result.sources.firstWhere((s) => s.source.name == 'MinMaxGames');
    final q = mmg.quotes.single;
    expect(q.converted, false);
    expect(q.price, 15);
    expect(q.currency, 'AUD');
  });
}
