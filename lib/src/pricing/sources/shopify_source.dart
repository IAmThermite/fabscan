import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/fab_card.dart';
import '../../models/price_quote.dart';
import '../price_source.dart';

/// Base class for Shopify storefronts (MinMaxGames, Fluke & Box, ...).
///
/// Shopify exposes a public predictive-search endpoint that returns products
/// with prices as JSON:
///
/// `GET {base}/search/suggest.json?q={query}&resources[type]=product&resources[limit]=10`
///
/// We map the returned products to [PriceQuote]s. No API key is required.
abstract class ShopifySource extends PriceSource {
  ShopifySource({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Storefront origin, e.g. `https://www.minmaxgames.com` (no trailing slash).
  String get baseUrl;

  static const Duration _timeout = Duration(seconds: 8);
  static const int _limit = 10;

  @override
  String searchUrl(FabCard card, CardPrint print) {
    final q = Uri.encodeQueryComponent(queryFor(card, print));
    return '$baseUrl/search?q=$q&type=product';
  }

  @override
  Future<List<PriceQuote>> fetchQuotes(FabCard card, CardPrint print) async {
    final query = queryFor(card, print);
    final uri = Uri.parse('$baseUrl/search/suggest.json').replace(
      queryParameters: {
        'q': query,
        'resources[type]': 'product',
        'resources[limit]': '$_limit',
      },
    );
    try {
      final resp = await _client.get(
        uri,
        headers: const {'Accept': 'application/json'},
      ).timeout(_timeout);
      if (resp.statusCode != 200) return const [];

      final body = jsonDecode(resp.body) as Map<String, Object?>;
      final products = _products(body);
      final lowerName = card.name.toLowerCase();

      final quotes = <PriceQuote>[];
      for (final raw in products) {
        if (raw is! Map) continue;
        final product = raw.cast<String, Object?>();
        final title = (product['title'] as String?)?.trim() ?? '';
        // Keep products that plausibly match the card name.
        if (lowerName.isNotEmpty &&
            !title.toLowerCase().contains(lowerName.split(' ').first.toLowerCase())) {
          continue;
        }
        final relUrl = product['url'] as String?;
        final price = _parsePrice(product['price']);
        quotes.add(PriceQuote(
          sourceName: name,
          title: title.isEmpty ? card.name : title,
          url: relUrl == null ? searchUrl(card, print) : '$baseUrl$relUrl',
          price: price,
          currency: currency,
          inStock: product['available'] != false,
          imageUrl: _image(product),
        ));
      }
      return quotes;
    } catch (_) {
      return const [];
    }
  }

  List<Object?> _products(Map<String, Object?> body) {
    final resources = body['resources'];
    if (resources is! Map) return const [];
    final results = (resources)['results'];
    if (results is! Map) return const [];
    final products = (results)['products'];
    return products is List ? products : const [];
  }

  /// Shopify suggest prices come through as strings like "12.00", "$12.00" or
  /// integer cents depending on theme; normalise to a double.
  double? _parsePrice(Object? raw) {
    if (raw == null) return null;
    if (raw is num) {
      // Heuristic: large integers are likely cents.
      return raw > 1000 ? raw / 100.0 : raw.toDouble();
    }
    final cleaned = raw.toString().replaceAll(RegExp(r'[^0-9.]'), '');
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
  }

  String? _image(Map<String, Object?> product) {
    final image = product['image'] ?? product['featured_image'];
    if (image is String && image.isNotEmpty) {
      return image.startsWith('//') ? 'https:$image' : image;
    }
    return null;
  }
}
