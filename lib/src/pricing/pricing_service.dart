import '../db/price_store.dart';
import '../models/fab_card.dart';
import '../models/price_quote.dart';
import 'currency.dart';
import 'price_source.dart';
import 'sources/fluke_and_box_source.dart';
import 'sources/link_out_source.dart';
import 'sources/minmax_games_source.dart';

/// Quotes gathered from one source for one card.
class SourceQuotes {
  const SourceQuotes({
    required this.source,
    required this.quotes,
    this.error = false,
  });

  final PriceSource source;
  final List<PriceQuote> quotes;
  final bool error;

  PriceQuote? get cheapest {
    final priced = quotes.where((q) => q.price != null).toList()
      ..sort((a, b) => a.price!.compareTo(b.price!));
    return priced.isEmpty ? null : priced.first;
  }
}

/// Pricing for a print across the configured sources, plus the dataset's
/// freshness so the UI can show "updated …".
class PriceResult {
  const PriceResult({
    required this.sources,
    required this.generatedAt,
    required this.displayCurrency,
  });

  final List<SourceQuotes> sources;
  final DateTime? generatedAt;
  final String displayCurrency;
}

/// Serves pricing from the locally cached dataset ([PriceStore]).
///
/// Prices are precomputed offline and downloaded by the remote-update flow, so
/// this does no network I/O. For each configured source it returns either a
/// stored, FX-converted price or — always, as a fallback — a link-out to the
/// site, so every source is at minimum tappable.
class PricingService {
  // `required this._store` exposes the param to callers as `store:`.
  PricingService({required this._store, List<PriceSource>? sources})
      : sources = sources ?? _defaultSources();

  static List<PriceSource> _defaultSources() => [
        MinMaxGamesSource(),
        FlukeAndBoxSource(),
        LinkOutSource.tcgplayer(),
        LinkOutSource.cardmarket(),
      ];

  final PriceStore _store;
  final List<PriceSource> sources;

  /// The currently selected display currency.
  Future<String> displayCurrency() => _store.displayCurrency();

  /// Changes the display currency for subsequent [quotesFor] calls.
  Future<void> setDisplayCurrency(String currency) =>
      _store.setDisplayCurrency(currency);

  /// Builds one [SourceQuotes] per configured source for [print], converting
  /// stored prices to the user's display currency and falling back to a
  /// link-out where no price is stored.
  Future<PriceResult> quotesFor(FabCard card, CardPrint print) async {
    final rows = await _store.quotesForPrint(print.id);
    final bySource = {for (final r in rows) r.source: r};
    final display = await _store.displayCurrency();
    final rates = await _store.fxRates();

    final out = [
      for (final s in sources)
        SourceQuotes(
          source: s,
          quotes: [_quoteFor(s, card, print, bySource[s.name], display, rates)],
        ),
    ];
    return PriceResult(
      sources: out,
      generatedAt: await _store.datasetGeneratedAt(),
      displayCurrency: display,
    );
  }

  PriceQuote _quoteFor(
    PriceSource source,
    FabCard card,
    CardPrint print,
    PriceQuoteRow? row,
    String display,
    Map<String, double> rates,
  ) {
    if (row != null && row.price != null) {
      final from = row.currency.isNotEmpty ? row.currency : source.currency;
      final converted = from == display
          ? row.price
          : convert(row.price!, from: from, to: display, rates: rates);
      final didConvert = converted != null && from != display;
      return PriceQuote(
        sourceName: source.name,
        title: card.name,
        url: (row.url != null && row.url!.isNotEmpty)
            ? row.url!
            : source.searchUrl(card, print),
        // Fall back to the unconverted price/currency when a rate is missing.
        price: converted ?? row.price,
        currency: didConvert ? display : from,
        inStock: row.inStock,
        converted: didConvert,
        originalPrice: didConvert ? row.price : null,
        originalCurrency: didConvert ? from : null,
      );
    }
    // No stored price → link-out (TCGplayer deep-links via print.tcgplayerUrl).
    return PriceQuote(
      sourceName: source.name,
      title: card.name,
      url: source.searchUrl(card, print),
      currency: source.currency,
    );
  }
}
