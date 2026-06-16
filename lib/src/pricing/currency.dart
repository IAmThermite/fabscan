/// View-time currency conversion using the FX rates shipped in the pricing
/// dataset. Rates are expressed as `units of currency per 1 [base]` (e.g. with
/// base USD, `rates['AUD'] = 1.52` means 1 USD = 1.52 AUD).
library;

/// Currencies the app offers as display options. These are the ones the source
/// sites quote in plus the rates we ship; the scraper's FX block must cover
/// every currency that appears in stored quotes so conversion never silently
/// fails for a quoted price.
const List<String> supportedDisplayCurrencies = [
  'NZD',
  'AUD',
  'USD',
  'EUR',
  'GBP',
];

/// Converts [amount] from currency [from] to [to] using [rates] (relative to
/// [base]). Returns null when either currency's rate is unknown, so callers can
/// fall back to showing the original, unconverted price.
double? convert(
  double amount, {
  required String from,
  required String to,
  required Map<String, double> rates,
}) {
  if (from == to) return amount;
  final fromRate = rates[from];
  final toRate = rates[to];
  if (fromRate == null || toRate == null || fromRate == 0) return null;
  return amount * (toRate / fromRate);
}
