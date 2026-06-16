import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/data/card_repository.dart';
import 'src/data/remote_update_service.dart';
import 'src/db/recents_store.dart';
import 'src/pricing/pricing_service.dart';
import 'src/ui/scan_screen.dart';

/// Root widget. Exposes the shared services to the widget tree via [Provider]
/// and opens on the live scanning screen.
class FabScanApp extends StatelessWidget {
  const FabScanApp({
    super.key,
    required this.repository,
    required this.recents,
    required this.pricing,
    required this.updates,
  });

  final CardRepository repository;
  final RecentsStore recents;
  final PricingService pricing;
  final RemoteUpdateService updates;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<CardRepository>.value(value: repository),
        Provider<RecentsStore>.value(value: recents),
        Provider<PricingService>.value(value: pricing),
        Provider<RemoteUpdateService>.value(value: updates),
      ],
      child: MaterialApp(
        title: 'FabScan',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFD32F2F),
            brightness: Brightness.dark,
          ),
        ),
        home: const ScanScreen(),
      ),
    );
  }
}
