import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// One stored price observation for a print from one source, as held in the
/// local `prices.db`. Currency is the *source's* currency (e.g. AUD); the UI
/// converts to the user's display currency at view time.
class PriceQuoteRow {
  const PriceQuoteRow({
    required this.printId,
    required this.source,
    this.price,
    required this.currency,
    this.url,
    this.inStock = true,
  });

  final String printId;

  /// MUST equal the corresponding [PriceSource.name] so the pricing service can
  /// join stored rows to configured sources (e.g. "MinMaxGames", "Fluke & Box").
  final String source;
  final double? price;
  final String currency;
  final String? url;
  final bool inStock;

  factory PriceQuoteRow.fromMap(Map<String, Object?> m) => PriceQuoteRow(
        printId: m['print_id'] as String,
        source: m['source'] as String,
        price: (m['price'] as num?)?.toDouble(),
        currency: (m['currency'] as String?) ?? '',
        url: m['url'] as String?,
        inStock: (m['in_stock'] as int? ?? 1) == 1,
      );

  Map<String, Object?> toMap() => {
        'print_id': printId,
        'source': source,
        'price': price,
        'currency': currency,
        'url': url,
        'in_stock': inStock ? 1 : 0,
      };
}

/// A small writable database holding the most recently downloaded pricing
/// dataset (one row per print/source) plus its metadata: the dataset
/// `generated_at` (when prices were scraped), the app `fetched_at` (when we
/// last downloaded), FX rates for view-time currency conversion, and the user's
/// chosen display currency.
///
/// This is fully app-owned and independent of the read-only bundled `cards.db`
/// (which is replaced wholesale on a [CardDatabase.bundledVersion] bump) — the
/// two must never be mixed.
class PriceStore {
  PriceStore._(this._db);

  final Database _db;

  static const String _dbName = 'prices.db';

  /// Default display currency. The app's user locale is NZ.
  static const String defaultCurrency = 'NZD';

  static const List<String> _schema = [
    '''
    CREATE TABLE IF NOT EXISTS prices (
      print_id TEXT NOT NULL,
      source   TEXT NOT NULL,
      price    REAL,
      currency TEXT NOT NULL,
      url      TEXT,
      in_stock INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY (print_id, source)
    )''',
    'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)',
  ];

  static Future<PriceStore> open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, _dbName);
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        for (final stmt in _schema) {
          await db.execute(stmt);
        }
      },
    );
    return PriceStore._(db);
  }

  /// Opens an in-memory store for tests. Set `databaseFactory =
  /// databaseFactoryFfi` (from `sqflite_common_ffi`) before calling.
  static Future<PriceStore> openInMemory() async {
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, _) async {
        for (final stmt in _schema) {
          await db.execute(stmt);
        }
      },
    );
    return PriceStore._(db);
  }

  // --- reads -----------------------------------------------------------------

  /// All stored quotes for a print, keyed in the caller by [PriceQuoteRow.source].
  Future<List<PriceQuoteRow>> quotesForPrint(String printId) async {
    final rows = await _db
        .query('prices', where: 'print_id = ?', whereArgs: [printId]);
    return rows.map(PriceQuoteRow.fromMap).toList();
  }

  /// When the dataset was scraped (shown to the user). Null when empty.
  Future<DateTime?> datasetGeneratedAt() async {
    final v = await _metaValue('generated_at');
    if (v == null) return null;
    return DateTime.tryParse(v);
  }

  /// When the app last successfully downloaded a dataset. Null when never.
  Future<DateTime?> fetchedAt() async {
    final v = await _metaValue('fetched_at');
    final ms = v == null ? null : int.tryParse(v);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// True when we have never fetched, or the last fetch is older than [maxAge].
  Future<bool> isStale(Duration maxAge) async {
    final f = await fetchedAt();
    if (f == null) return true;
    return DateTime.now().difference(f) > maxAge;
  }

  Future<String?> fxBase() => _metaValue('fx_base');

  /// FX rates as `currency -> units per 1 [fxBase]`. Empty when unavailable.
  Future<Map<String, double>> fxRates() async {
    final raw = await _metaValue('fx_rates');
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      return decoded.map((k, v) => MapEntry(k, (v as num).toDouble()));
    } catch (_) {
      return const {};
    }
  }

  /// The user's chosen display currency (defaults to [defaultCurrency]).
  Future<String> displayCurrency() async =>
      await _metaValue('display_currency') ?? defaultCurrency;

  Future<void> setDisplayCurrency(String currency) =>
      _setMeta('display_currency', currency);

  /// Marks the dataset as freshly checked without changing it — used when the
  /// remote dataset is unchanged, so we don't re-download until the next
  /// staleness window. No-op when the store has never been populated.
  Future<void> touchFetchedAt() async {
    if (await datasetGeneratedAt() == null) return;
    await _setMeta('fetched_at', DateTime.now().millisecondsSinceEpoch.toString());
  }

  // --- writes ----------------------------------------------------------------

  /// Replaces the entire dataset atomically: clears old rows, inserts [rows] in
  /// one batch, and updates the data/FX/timestamp metadata. The user's
  /// `display_currency` preference is intentionally left untouched.
  Future<void> replaceAll({
    required String generatedAt,
    required int datasetSchemaVersion,
    String? fxBase,
    Map<String, double>? fxRates,
    required List<PriceQuoteRow> rows,
  }) async {
    await _db.transaction((txn) async {
      await txn.delete('prices');
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert('prices', r.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);

      Future<void> meta(String k, String v) => txn.insert(
            'meta',
            {'key': k, 'value': v},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
      await meta('generated_at', generatedAt);
      await meta('fetched_at', DateTime.now().millisecondsSinceEpoch.toString());
      await meta('dataset_schema_version', '$datasetSchemaVersion');
      if (fxBase != null) await meta('fx_base', fxBase);
      if (fxRates != null) await meta('fx_rates', jsonEncode(fxRates));
    });
  }

  Future<String?> _metaValue(String key) async {
    final rows = await _db.query('meta',
        columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _setMeta(String key, String value) => _db.insert(
        'meta',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> close() => _db.close();
}
