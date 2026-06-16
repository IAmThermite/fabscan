import '../../models/fab_card.dart';
import '../price_source.dart';

/// Base class for Shopify storefronts (MinMaxGames, Fluke & Box, ...).
///
/// Prices for these stores are scraped offline (the daily Python job crawls
/// each store's public `/products.json`), so on-device we only need the
/// link-out: Shopify's `/search?q=...` page for the card.
abstract class ShopifySource extends PriceSource {
  /// Storefront origin, e.g. `https://www.minmaxgames.com` (no trailing slash).
  String get baseUrl;

  @override
  String searchUrl(FabCard card, CardPrint print) {
    final q = Uri.encodeQueryComponent(queryFor(card, print));
    return '$baseUrl/search?q=$q&type=product';
  }
}
