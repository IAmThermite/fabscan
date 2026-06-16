import 'dart:convert';

import '../db/price_store.dart';

/// A parsed `prices.json` payload, ready to hand to [PriceStore.replaceAll].
class PriceDataset {
  const PriceDataset({
    required this.schemaVersion,
    required this.generatedAt,
    this.fxBase,
    this.fxRates,
    required this.rows,
  });

  final int schemaVersion;
  final String generatedAt;
  final String? fxBase;
  final Map<String, double>? fxRates;
  final List<PriceQuoteRow> rows;
}

/// The highest `schema_version` of `prices.json` this build understands. A
/// payload with a higher version is rejected (we keep existing data rather than
/// import a shape we can't read).
const int supportedPriceSchemaVersion = 1;

/// Parses a decoded `prices.json` map into a [PriceDataset], or returns null
/// when the payload is malformed or its schema is too new.
///
/// Shape (short keys keep the file small):
/// ```
/// { "schema_version": 1, "generated_at": "ISO8601",
///   "fx": {"base":"USD","rates":{"USD":1,"AUD":1.52,...}},
///   "prints": { "<print_id>": { "MinMaxGames": {"p":12.5,"c":"AUD","u":"...","s":true} } } }
/// ```
PriceDataset? parsePriceDataset(Map<String, Object?> body) {
  final schemaVersion = (body['schema_version'] as num?)?.toInt();
  if (schemaVersion == null || schemaVersion > supportedPriceSchemaVersion) {
    return null;
  }
  final generatedAt = body['generated_at'] as String?;
  if (generatedAt == null || generatedAt.isEmpty) return null;

  String? fxBase;
  Map<String, double>? fxRates;
  final fx = body['fx'];
  if (fx is Map) {
    fxBase = fx['base'] as String?;
    final rates = fx['rates'];
    if (rates is Map) {
      fxRates = <String, double>{};
      rates.forEach((k, v) {
        if (v is num) fxRates![k as String] = v.toDouble();
      });
    }
  }

  final rows = <PriceQuoteRow>[];
  final prints = body['prints'];
  if (prints is Map) {
    prints.forEach((printId, sources) {
      if (sources is! Map) return;
      sources.forEach((sourceName, q) {
        if (q is! Map) return;
        rows.add(PriceQuoteRow(
          printId: printId as String,
          source: sourceName as String,
          price: (q['p'] as num?)?.toDouble(),
          currency: (q['c'] as String?) ?? '',
          url: q['u'] as String?,
          inStock: q['s'] != false,
        ));
      });
    });
  }

  return PriceDataset(
    schemaVersion: schemaVersion,
    generatedAt: generatedAt,
    fxBase: fxBase,
    fxRates: fxRates,
    rows: rows,
  );
}

/// Convenience: parse from a raw JSON string. Returns null on any failure.
PriceDataset? parsePriceDatasetJson(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) return null;
    return parsePriceDataset(decoded);
  } catch (_) {
    return null;
  }
}
