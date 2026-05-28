import 'shopify_source.dart';

/// MinMaxGames — Australian Flesh and Blood specialist (Shopify storefront).
class MinMaxGamesSource extends ShopifySource {
  MinMaxGamesSource({super.client});

  @override
  String get name => 'MinMaxGames';

  @override
  String get currency => 'AUD';

  @override
  String get baseUrl => 'https://www.minmaxgames.com';
}
