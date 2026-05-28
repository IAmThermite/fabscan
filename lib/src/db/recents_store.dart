import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/fab_card.dart';

/// A card the user recently scanned, kept for a rolling 24-hour window.
class RecentScan {
  const RecentScan({
    required this.faceId,
    required this.cardId,
    required this.name,
    required this.scannedAt,
    this.setCode,
    this.imageUrl,
    this.pitch,
  });

  final String faceId;
  final String cardId;
  final String name;
  final String? setCode;
  final String? imageUrl;
  final int? pitch;
  final DateTime scannedAt;

  factory RecentScan.fromMap(Map<String, Object?> m) => RecentScan(
        faceId: m['face_id'] as String,
        cardId: m['card_id'] as String,
        name: m['name'] as String,
        setCode: m['set_code'] as String?,
        imageUrl: m['image_url'] as String?,
        pitch: m['pitch'] as int?,
        scannedAt:
            DateTime.fromMillisecondsSinceEpoch(m['scanned_at'] as int),
      );
}

/// A small writable database that records recently scanned cards and
/// automatically expires anything older than [retention].
class RecentsStore {
  RecentsStore._(this._db);

  final Database _db;

  static const Duration retention = Duration(hours: 24);

  static Future<RecentsStore> open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'recents.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE recents (
            face_id TEXT PRIMARY KEY,
            card_id TEXT NOT NULL,
            name TEXT NOT NULL,
            set_code TEXT,
            image_url TEXT,
            pitch INTEGER,
            scanned_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_recents_time ON recents(scanned_at)');
      },
    );
    final store = RecentsStore._(db);
    await store._purgeExpired();
    return store;
  }

  Future<void> _purgeExpired() async {
    final cutoff =
        DateTime.now().subtract(retention).millisecondsSinceEpoch;
    await _db.delete('recents', where: 'scanned_at < ?', whereArgs: [cutoff]);
  }

  /// Records a scan. Re-scanning the same print refreshes its timestamp
  /// (so it stays at the top and its 24h window restarts).
  Future<void> record(FabCard card, CardPrint print) async {
    await _db.insert(
      'recents',
      {
        'face_id': print.faceId,
        'card_id': card.id,
        'name': card.name,
        'set_code': print.setCode,
        'image_url': print.imageUrl,
        'pitch': card.pitch,
        'scanned_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<RecentScan>> list() async {
    await _purgeExpired();
    final rows = await _db.query('recents', orderBy: 'scanned_at DESC');
    return rows.map(RecentScan.fromMap).toList();
  }

  Future<void> clear() => _db.delete('recents');

  Future<void> close() => _db.close();
}
