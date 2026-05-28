/// A single price observation for a card from one source.
///
/// When [price] is null the quote is a "link-out" only — the source couldn't
/// (or doesn't) expose a machine-readable price, so the app just offers [url]
/// to open the listing.
class PriceQuote {
  const PriceQuote({
    required this.sourceName,
    required this.title,
    required this.url,
    this.price,
    this.currency = '',
    this.inStock = true,
    this.imageUrl,
  });

  final String sourceName;
  final String title;
  final String url;
  final double? price;
  final String currency;
  final bool inStock;
  final String? imageUrl;

  bool get isLinkOnly => price == null;

  String get displayPrice {
    if (price == null) return '—';
    final symbol = _symbols[currency] ?? '';
    final amount = price!.toStringAsFixed(2);
    return symbol.isEmpty ? '$amount $currency'.trim() : '$symbol$amount';
  }

  static const Map<String, String> _symbols = {
    'USD': r'$',
    'AUD': r'A$',
    'NZD': r'NZ$',
    'EUR': '€',
    'GBP': '£',
  };
}
