import '../models/fab_card.dart';
import '../models/price_quote.dart';
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

/// Aggregates pricing across the configured 3rd-party sources.
class PricingService {
  PricingService({List<PriceSource>? sources})
      : sources = sources ??
            [
              MinMaxGamesSource(),
              FlukeAndBoxSource(),
              LinkOutSource.tcgplayer(),
              LinkOutSource.cardmarket(),
            ];

  final List<PriceSource> sources;

  /// Fetches quotes from every source concurrently. Each source is isolated:
  /// one failing or timing out doesn't block the others.
  Future<List<SourceQuotes>> fetchAll(FabCard card, CardPrint print) {
    return Future.wait(sources.map((s) async {
      try {
        final quotes = await s.fetchQuotes(card, print);
        return SourceQuotes(source: s, quotes: quotes);
      } catch (_) {
        return SourceQuotes(source: s, quotes: const [], error: true);
      }
    }));
  }
}
