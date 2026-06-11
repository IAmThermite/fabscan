import 'package:fabscan/src/db/card_dao.dart';
import 'package:fabscan/src/models/fab_card.dart';
import 'package:fabscan/src/models/price_quote.dart';
import 'package:fabscan/src/pricing/sources/link_out_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CardPrint', () {
    test('variantLabel composes set and art type', () {
      const print = CardPrint(
        id: '1',
        cardId: 'c1',
        faceId: 'WTR001',
        setCode: 'WTR',
        artType: 'extended-art',
      );
      expect(print.variantLabel, 'WTR · Extended Art');
    });

    test('round-trips through toMap/fromMap', () {
      const print = CardPrint(
        id: '1',
        cardId: 'c1',
        faceId: 'WTR001',
        setCode: 'WTR',
        artType: 'regular',
        orientation: 'vertical',
        imagePhash: 123456789,
        artBbox: ArtBbox.defaultRegular,
        tcgplayerUrl: 'https://www.tcgplayer.com/product/1?Language=English',
      );
      final restored = CardPrint.fromMap(print.toMap());
      expect(restored.faceId, 'WTR001');
      expect(restored.imagePhash, 123456789);
      expect(restored.artBbox?.w, ArtBbox.defaultRegular.w);
      expect(restored.tcgplayerUrl,
          'https://www.tcgplayer.com/product/1?Language=English');
    });
  });

  group('LinkOutSource.tcgplayer', () {
    const card = FabCard(id: 'c1', name: 'Rhinar, Reckless Rampage');

    test('deep-links to the print product page when present', () {
      const print = CardPrint(
        id: '1',
        cardId: 'c1',
        faceId: 'MST001',
        tcgplayerUrl: 'https://www.tcgplayer.com/product/551703?Language=English',
      );
      expect(LinkOutSource.tcgplayer().searchUrl(card, print),
          'https://www.tcgplayer.com/product/551703?Language=English');
    });

    test('falls back to search when the print has no product url', () {
      const print = CardPrint(id: '2', cardId: 'c1', faceId: 'OMN001');
      final url = LinkOutSource.tcgplayer().searchUrl(card, print);
      expect(url, contains('/search/flesh-and-blood-tcg/product'));
      expect(url, contains('q=Rhinar'));
    });
  });

  group('PriceQuote', () {
    test('formats a priced quote with a currency symbol', () {
      const q = PriceQuote(
        sourceName: 'MinMaxGames',
        title: 'Card',
        url: 'https://example.com',
        price: 12.5,
        currency: 'AUD',
      );
      expect(q.displayPrice, r'A$12.50');
      expect(q.isLinkOnly, false);
    });

    test('a price-less quote is link-only', () {
      const q = PriceQuote(
        sourceName: 'TCGplayer',
        title: 'Card',
        url: 'https://example.com',
      );
      expect(q.isLinkOnly, true);
      expect(q.displayPrice, '—');
    });
  });

  group('ScanHashes', () {
    test('holds the multi-arm hashes', () {
      const h = ScanHashes(art: 1, full: 3);
      expect(h.art, 1);
      expect(h.full, 3);
    });
  });
}
