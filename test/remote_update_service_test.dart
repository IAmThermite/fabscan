import 'package:fabscan/src/data/card_repository.dart';
import 'package:fabscan/src/data/remote_update_service.dart';
import 'package:fabscan/src/db/card_dao.dart';
import 'package:fabscan/src/db/card_database.dart';
import 'package:fabscan/src/db/price_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _pricesJson = '{"schema_version":1,"generated_at":"2026-06-17T03:00:00Z",'
    '"fx":{"base":"USD","rates":{"USD":1,"AUD":1.5,"NZD":1.6}},'
    '"prints":{"print-1":{"MinMaxGames":{"p":12.5,"c":"AUD","u":"https://mmg/x","s":true}}}}';

String _manifest({int schemaVersion = 1, String generatedAt = '2026-06-17T03:00:00Z'}) =>
    '{"schema_version":$schemaVersion,'
    '"prices":{"url":"https://host/prices.json","generated_at":"$generatedAt"}}';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late PriceStore store;
  late CardDatabase cardDb;
  late CardRepository repo;

  setUp(() async {
    store = await PriceStore.openInMemory();
    cardDb = CardDatabase.forTesting(await openDatabase(inMemoryDatabasePath));
    repo = CardRepository(CardDao(cardDb.db));
  });

  tearDown(() async {
    await store.close();
    await cardDb.close();
  });

  RemoteUpdateService service(MockClient client) => RemoteUpdateService(
        priceStore: store,
        cardDatabase: cardDb,
        repository: repo,
        client: client,
        manifestUrl: Uri.parse('https://host/manifest.json'),
      );

  test('downloads and stores prices when the dataset is new', () async {
    var pricesHits = 0;
    final client = MockClient((req) async {
      if (req.url.path.endsWith('manifest.json')) {
        return http.Response(_manifest(), 200);
      }
      if (req.url.path.endsWith('prices.json')) {
        pricesHits++;
        return http.Response(_pricesJson, 200);
      }
      return http.Response('nope', 404);
    });

    final svc = service(client);
    await svc.checkForUpdates();

    expect(pricesHits, 1);
    expect(await store.quotesForPrint('print-1'), hasLength(1));
    expect(await store.datasetGeneratedAt(),
        DateTime.parse('2026-06-17T03:00:00Z'));
    expect(svc.pricesUpdatedTick.value, 1);
    expect(svc.refreshing.value, false);
  });

  test('does not re-download when fresh and unchanged', () async {
    // Pre-populate with the same generated_at the manifest reports.
    await store.replaceAll(
      generatedAt: '2026-06-17T03:00:00Z',
      datasetSchemaVersion: 1,
      rows: const [
        PriceQuoteRow(printId: 'print-1', source: 'MinMaxGames', price: 1, currency: 'AUD'),
      ],
    );

    var pricesHits = 0;
    final client = MockClient((req) async {
      if (req.url.path.endsWith('manifest.json')) {
        return http.Response(_manifest(), 200);
      }
      pricesHits++;
      return http.Response(_pricesJson, 200);
    });

    await service(client).checkForUpdates();
    // Fresh (just populated) → isStale is false → not even the manifest gates a
    // download; the big prices.json is never fetched.
    expect(pricesHits, 0);
  });

  test('a too-new manifest schema is ignored (keeps existing data)', () async {
    final client = MockClient((req) async {
      if (req.url.path.endsWith('manifest.json')) {
        return http.Response(_manifest(schemaVersion: 99), 200);
      }
      return http.Response(_pricesJson, 200);
    });

    await service(client).checkForUpdates();
    expect(await store.quotesForPrint('print-1'), isEmpty);
  });

  test('network failure leaves the store untouched', () async {
    final client = MockClient((req) async => http.Response('boom', 500));
    final svc = service(client);
    await svc.checkForUpdates(); // must not throw
    expect(await store.datasetGeneratedAt(), isNull);
    expect(svc.refreshing.value, false);
  });
}
