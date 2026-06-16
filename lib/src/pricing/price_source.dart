import '../models/fab_card.dart';

/// A 3rd-party site we show pricing for.
///
/// Live prices are no longer fetched on-device — they're precomputed daily by
/// `tool/scrape_prices.py` and downloaded into the local `prices.db`. A
/// `PriceSource` now just supplies the site's identity (name/currency) and the
/// link-out URL used both as the always-available fallback and as the
/// destination when a stored price is tapped without an exact listing URL.
abstract class PriceSource {
  String get name;

  /// ISO currency code the source quotes in (e.g. "AUD", "NZD", "USD").
  String get currency;

  /// A URL the user can open to view this card on the source site.
  String searchUrl(FabCard card, CardPrint print);

  /// Builds the query string used to look up [card] on the source.
  /// Most singles sites search well on the bare card name.
  String queryFor(FabCard card, CardPrint print) => card.name;
}
