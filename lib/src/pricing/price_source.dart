import '../models/fab_card.dart';
import '../models/price_quote.dart';

/// A source of pricing for a card from a 3rd-party site.
///
/// Implementations either fetch live quotes (e.g. Shopify storefronts expose a
/// JSON search endpoint) or simply provide a deep link to the site's search
/// results when no machine-readable price is available.
abstract class PriceSource {
  String get name;

  /// ISO currency code the source quotes in (e.g. "AUD", "NZD", "USD").
  String get currency;

  /// A URL the user can open to view this card on the source site.
  String searchUrl(FabCard card, CardPrint print);

  /// Fetches live quotes. Returns an empty list when the source can't provide
  /// a price programmatically (callers then fall back to [searchUrl]).
  Future<List<PriceQuote>> fetchQuotes(FabCard card, CardPrint print);

  /// Builds the query string used to look up [card] on the source.
  /// Most singles sites search well on the bare card name.
  String queryFor(FabCard card, CardPrint print) => card.name;
}
