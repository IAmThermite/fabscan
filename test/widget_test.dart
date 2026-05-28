import 'package:fabscan/src/db/card_dao.dart';
import 'package:fabscan/src/models/fab_card.dart';
import 'package:fabscan/src/models/price_quote.dart';
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
      );
      final restored = CardPrint.fromMap(print.toMap());
      expect(restored.faceId, 'WTR001');
      expect(restored.imagePhash, 123456789);
      expect(restored.artBbox?.w, ArtBbox.defaultRegular.w);
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
