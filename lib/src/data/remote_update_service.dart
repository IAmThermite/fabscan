import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../db/card_dao.dart';
import '../db/card_database.dart';
import '../db/price_store.dart';
import '../pricing/price_dataset.dart';
import 'card_repository.dart';

/// Checks a small remote `manifest.json` on launch and applies any available
/// updates to the two data stores, entirely in the background:
///
///   * **prices** — downloaded into [PriceStore] at most once per [priceMaxAge]
///     and only when the dataset's `generated_at` has changed.
///   * **card DB** — a new `cards.db` is pulled and hot-swapped *whenever* the
///     manifest's `card_db.version` differs from the installed DB, so card data
///     is never stale when a newer build exists (no app release required).
///
/// Every step is best-effort and never throws: on no internet, a timeout, a
/// non-200, or a parse error the existing on-device data is left untouched and
/// the app carries on (stale prices, then link-out fallback).
///
/// Manifest shape:
/// ```
/// { "schema_version": 1,
///   "prices":  {"url": "...", "generated_at": "ISO8601"},
///   "card_db": {"url": "...", "version": "2026-06-17.ab12cd"} }
/// ```
///
/// Not a [ChangeNotifier] (so it can be shared via a plain [Provider]); UI
/// observes the [refreshing] / [pricesUpdatedTick] notifiers directly.
class RemoteUpdateService {
  // `this._priceStore` / `this._repository` expose params as `priceStore:` /
  // `repository:` to callers.
  RemoteUpdateService({
    required this._priceStore,
    required CardDatabase cardDatabase,
    required this._repository,
    http.Client? client,
    Uri? manifestUrl,
    this.priceMaxAge = const Duration(hours: 24),
  })  : _cardDb = cardDatabase,
        _client = client ?? http.Client(),
        _manifestUrl = manifestUrl ?? Uri.parse(defaultManifestUrl);

  /// Where the published manifest lives (GitHub Pages for `IAmThermite/fabscan`).
  static const String defaultManifestUrl =
      'https://iamthermite.github.io/fabscan/manifest.json';

  /// Highest manifest `schema_version` this build understands.
  static const int _supportedSchemaVersion = 1;

  static const Duration _manifestTimeout = Duration(seconds: 12);
  static const Duration _downloadTimeout = Duration(seconds: 30);

  final PriceStore _priceStore;
  CardDatabase _cardDb;
  final CardRepository _repository;
  final http.Client _client;
  final Uri _manifestUrl;
  final Duration priceMaxAge;

  /// True while a check is in flight; the price panel surfaces this as a small
  /// "Checking for updates…" indicator.
  final ValueNotifier<bool> refreshing = ValueNotifier<bool>(false);

  /// True after a price refresh that actually changed the dataset this session,
  /// so an open price panel can re-read the store.
  final ValueNotifier<int> pricesUpdatedTick = ValueNotifier<int>(0);

  bool _inFlight = false;

  /// Fire-and-forget entry point. Safe to call from `main` after `runApp`.
  Future<void> checkForUpdates() async {
    if (_inFlight) return;
    _inFlight = true;
    refreshing.value = true;
    try {
      final manifest = await _fetchManifest();
      if (manifest == null) return;
      final sv = (manifest['schema_version'] as num?)?.toInt();
      if (sv == null || sv > _supportedSchemaVersion) return;

      // Card DB first: keep it isolated so a price failure can't block it.
      await _maybeUpdateCardDb(manifest['card_db']);
      await _maybeUpdatePrices(manifest['prices']);
    } finally {
      refreshing.value = false;
      _inFlight = false;
    }
  }

  Future<Map<String, Object?>?> _fetchManifest() async {
    try {
      final resp = await _client
          .get(_manifestUrl, headers: const {'Accept': 'application/json'})
          .timeout(_manifestTimeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _maybeUpdateCardDb(Object? section) async {
    try {
      if (section is! Map) return;
      final url = section['url'] as String?;
      final version = section['version'] as String?;
      if (url == null || version == null) return;
      if (version == await _cardDb.installedVersion()) return;

      final uri = Uri.tryParse(url);
      if (uri == null) return;
      final resp = await _client.get(uri).timeout(_downloadTimeout);
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return;

      final newDb = await _cardDb.replaceWith(resp.bodyBytes, version);
      _cardDb = newDb;
      _repository.replaceDao(CardDao(newDb.db));
    } catch (_) {
      // Keep the existing DB on any failure.
    }
  }

  Future<void> _maybeUpdatePrices(Object? section) async {
    try {
      if (section is! Map) return;
      final url = section['url'] as String?;
      final remoteGeneratedAt = section['generated_at'] as String?;
      if (url == null || remoteGeneratedAt == null) return;

      if (!await _priceStore.isStale(priceMaxAge)) return;

      // Skip the (larger) download when the dataset hasn't changed; still mark
      // the check as done so we don't retry until the next staleness window.
      final current = await _priceStore.datasetGeneratedAt();
      if (current != null &&
          current.toIso8601String() == DateTime.tryParse(remoteGeneratedAt)?.toIso8601String()) {
        await _priceStore.touchFetchedAt();
        return;
      }

      final uri = Uri.tryParse(url);
      if (uri == null) return;
      final resp = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(_downloadTimeout);
      if (resp.statusCode != 200) return;

      final dataset = parsePriceDatasetJson(resp.body);
      if (dataset == null) return;

      await _priceStore.replaceAll(
        generatedAt: dataset.generatedAt,
        datasetSchemaVersion: dataset.schemaVersion,
        fxBase: dataset.fxBase,
        fxRates: dataset.fxRates,
        rows: dataset.rows,
      );
      pricesUpdatedTick.value++;
    } catch (_) {
      // Keep the existing prices on any failure.
    }
  }

  /// Releases the HTTP client and notifiers. The service is an app-lifetime
  /// singleton, so this is mainly for tests.
  void dispose() {
    _client.close();
    refreshing.dispose();
    pricesUpdatedTick.dispose();
  }
}
