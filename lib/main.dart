import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'src/data/card_repository.dart';
import 'src/db/card_dao.dart';
import 'src/db/card_database.dart';
import 'src/db/recents_store.dart';
import 'src/pricing/pricing_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The scan UI and camera-frame geometry assume a portrait frame; lock it.
  await SystemChrome.setPreferredOrientations(
    [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
  );

  // Open the bundled (read-only) card database and the writable recents store.
  final cardDb = await CardDatabase.open();
  final repository = CardRepository(CardDao(cardDb.db));
  final recents = await RecentsStore.open();

  runApp(
    FabScanApp(
      repository: repository,
      recents: recents,
      pricing: PricingService(),
    ),
  );
}
