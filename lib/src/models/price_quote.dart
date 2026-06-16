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
    this.converted = false,
    this.originalPrice,
    this.originalCurrency,
  });

  final String sourceName;
  final String title;
  final String url;

  /// Price in [currency] — already converted to the user's display currency
  /// when [converted] is true.
  final double? price;
  final String currency;
  final bool inStock;
  final String? imageUrl;

  /// True when [price]/[currency] are the result of an FX conversion from
  /// [originalPrice]/[originalCurrency] (the source's own quote). UIs show an
  /// approximate marker ("≈") in that case.
  final bool converted;
  final double? originalPrice;
  final String? originalCurrency;

  bool get isLinkOnly => price == null;

  /// Formatted price, prefixed with "≈" when it was FX-converted.
  String get displayPrice {
    if (price == null) return '—';
    final symbol = _symbols[currency] ?? '';
    final amount = price!.toStringAsFixed(2);
    final formatted = symbol.isEmpty ? '$amount $currency'.trim() : '$symbol$amount';
    return converted ? '≈$formatted' : formatted;
  }

  /// The source's original quote, formatted (e.g. "A$12.50"). Null unless this
  /// quote was converted. Useful as a tooltip alongside [displayPrice].
  String? get originalDisplayPrice {
    if (!converted || originalPrice == null) return null;
    final symbol = _symbols[originalCurrency] ?? '';
    final amount = originalPrice!.toStringAsFixed(2);
    return symbol.isEmpty
        ? '$amount $originalCurrency'.trim()
        : '$symbol$amount';
  }

  static const Map<String, String> _symbols = {
    'USD': r'$',
    'AUD': r'A$',
    'NZD': r'NZ$',
    'EUR': '€',
    'GBP': '£',
  };
}
