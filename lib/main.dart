import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'src/data/card_repository.dart';
import 'src/data/remote_update_service.dart';
import 'src/db/card_dao.dart';
import 'src/db/card_database.dart';
import 'src/db/price_store.dart';
import 'src/db/recents_store.dart';
import 'src/pricing/price_dataset.dart';
import 'src/pricing/pricing_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The scan UI and camera-frame geometry assume a portrait frame; lock it.
  await SystemChrome.setPreferredOrientations(
    [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
  );

  // Open the bundled (read-only) card database and the writable stores.
  final cardDb = await CardDatabase.open();
  final repository = CardRepository(CardDao(cardDb.db));
  final recents = await RecentsStore.open();
  final priceStore = await PriceStore.open();
  await _seedPricesIfEmpty(priceStore);

  final pricing = PricingService(store: priceStore);
  final updates = RemoteUpdateService(
    priceStore: priceStore,
    cardDatabase: cardDb,
    repository: repository,
  );

  runApp(
    FabScanApp(
      repository: repository,
      recents: recents,
      pricing: pricing,
      updates: updates,
    ),
  );

  // Background, fire-and-forget (so the scan screen opens immediately): refresh
  // prices at most once per 24h and pull a newer card DB whenever one exists.
  unawaited(updates.checkForUpdates());
}

/// Loads a bundled `assets/prices.json` into the empty store on first run so
/// day-one launches show prices offline. A no-op when no seed asset is shipped
/// (the app then starts with link-out-only pricing until the first refresh).
Future<void> _seedPricesIfEmpty(PriceStore store) async {
  if (await store.fetchedAt() != null) return;
  try {
    final json = await rootBundle.loadString('assets/prices.json');
    final dataset = parsePriceDatasetJson(json);
    if (dataset == null) return;
    await store.replaceAll(
      generatedAt: dataset.generatedAt,
      datasetSchemaVersion: dataset.schemaVersion,
      fxBase: dataset.fxBase,
      fxRates: dataset.fxRates,
      rows: dataset.rows,
    );
  } catch (_) {
    // No (or unreadable) seed asset — start empty.
  }
}
