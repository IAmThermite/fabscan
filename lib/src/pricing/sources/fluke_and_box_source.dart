import 'shopify_source.dart';

/// Fluke & Box — Flesh and Blood specialist (Shopify storefront).
class FlukeAndBoxSource extends ShopifySource {
  @override
  String get name => 'Fluke & Box';

  // TODO(pricing): confirm storefront currency (assumed NZD).
  @override
  String get currency => 'NZD';

  @override
  String get baseUrl => 'https://www.flukeandbox.com';
}
