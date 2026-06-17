import 'shopify_source.dart';

/// MinMaxGames — Australian Flesh and Blood specialist (Shopify storefront).
///
/// Uses the FAB-specific storefront (minmaxgamesfab.com) — the same store the
/// price scraper crawls, so a tapped link-out lands on the catalogue the prices
/// came from. [currency] is only the link-out fallback; stored quotes carry the
/// currency detected from the shop at scrape time.
class MinMaxGamesSource extends ShopifySource {
  @override
  String get name => 'MinMaxGames';

  @override
  String get currency => 'AUD';

  @override
  String get baseUrl => 'https://minmaxgamesfab.com';
}
