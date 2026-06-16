import 'shopify_source.dart';

/// MinMaxGames — Australian Flesh and Blood specialist (Shopify storefront).
class MinMaxGamesSource extends ShopifySource {
  @override
  String get name => 'MinMaxGames';

  @override
  String get currency => 'AUD';

  @override
  String get baseUrl => 'https://www.minmaxgames.com';
}
