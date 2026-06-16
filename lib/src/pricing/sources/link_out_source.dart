import '../../models/fab_card.dart';
import '../price_source.dart';

/// A source we link out to. TCGplayer and Cardmarket gate pricing behind
/// registered API keys, so the daily scraper only best-effort scrapes them; in
/// the app these always at minimum offer a tappable deep link to the site.
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
