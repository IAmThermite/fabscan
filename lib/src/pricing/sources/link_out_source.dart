import '../../models/fab_card.dart';
import '../../models/price_quote.dart';
import '../price_source.dart';

/// A source that has no open price API, so it only deep-links to its search
/// page. Used for TCGplayer and Cardmarket (both gate pricing behind
/// registered API keys).
///
/// [fetchQuotes] returns a single price-less quote carrying the search URL, so
/// the source still appears in the price panel as a tappable link.
class LinkOutSource extends PriceSource {
  LinkOutSource({
    required this.name,
    required this.currency,
    required this.buildUrl,
    this.directUrl,
  });

  @override
  final String name;

  @override
  final String currency;

  /// Builds the destination URL from a search query.
  final String Function(String query) buildUrl;

  /// Optional deep link to the exact [print]'s product page. When it returns a
  /// non-null URL it's preferred over the search page; otherwise we fall back
  /// to [buildUrl].
  final String? Function(CardPrint print)? directUrl;

  @override
  String searchUrl(FabCard card, CardPrint print) =>
      directUrl?.call(print) ?? buildUrl(queryFor(card, print));

  @override
  Future<List<PriceQuote>> fetchQuotes(FabCard card, CardPrint print) async {
    return [
      PriceQuote(
        sourceName: name,
        title: card.name,
        url: searchUrl(card, print),
        currency: currency,
      ),
    ];
  }

  /// TCGplayer: deep-links to the exact printing's product page when the card
  /// data carries one, else falls back to the Flesh and Blood search.
  factory LinkOutSource.tcgplayer() => LinkOutSource(
        name: 'TCGplayer',
        currency: 'USD',
        directUrl: (print) => print.tcgplayerUrl,
        buildUrl: (q) =>
            'https://www.tcgplayer.com/search/flesh-and-blood-tcg/product'
            '?productLineName=flesh-and-blood-tcg&q=${Uri.encodeQueryComponent(q)}',
      );

  /// Cardmarket Flesh and Blood search.
  factory LinkOutSource.cardmarket() => LinkOutSource(
        name: 'Cardmarket',
        currency: 'EUR',
        buildUrl: (q) =>
            'https://www.cardmarket.com/en/FleshAndBlood/Products/Search'
            '?searchString=${Uri.encodeQueryComponent(q)}',
      );
}
