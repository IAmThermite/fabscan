import 'package:fabscan/src/pricing/currency.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('convert', () {
    const rates = {'USD': 1.0, 'AUD': 1.5, 'NZD': 1.6, 'EUR': 0.9};

    test('same currency is identity', () {
      expect(convert(10, from: 'AUD', to: 'AUD', rates: rates), 10);
    });

    test('converts via the base', () {
      // 15 AUD -> USD: 15 * (1 / 1.5) = 10; -> NZD: 10 * 1.6 = 16.
      expect(convert(15, from: 'AUD', to: 'USD', rates: rates), closeTo(10, 1e-9));
      expect(convert(15, from: 'AUD', to: 'NZD', rates: rates), closeTo(16, 1e-9));
    });

    test('returns null when a rate is missing', () {
      expect(convert(10, from: 'AUD', to: 'GBP', rates: rates), isNull);
      expect(convert(10, from: 'JPY', to: 'USD', rates: rates), isNull);
    });

    test('NZD is the default display currency', () {
      expect(supportedDisplayCurrencies.first, 'NZD');
    });
  });
}
