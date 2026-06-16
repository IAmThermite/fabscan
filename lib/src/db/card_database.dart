import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Opens the bundled, read-only card database.
///
/// On first launch (or when the app ships a newer bundled DB) the asset at
/// `assets/cards.db` is copied into the app's databases directory. If that
/// asset is missing (e.g. before `tool/build_card_db.dart` has been run) an
/// empty database with the correct schema is created instead, so the app
/// still launches — it simply won't return any matches.
class CardDatabase {
  CardDatabase._(this.db);

  /// Wraps an already-open database (e.g. an in-memory one) for tests.
  CardDatabase.forTesting(this.db);

  final Database db;

  /// Asset path of the prebuilt database.
  static const String _assetPath = 'assets/cards.db';

  /// Bump this (and the value written by the build tool) to force the bundled
  /// DB to replace a previously-copied one after an app update.
  static const String bundledVersion = 'dev4';

  /// CREATE statements; kept in sync with `tool/build_card_db.dart`.
  static const List<String> schema = [
    '''
    CREATE TABLE IF NOT EXISTS cards (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      pitch INTEGER,
      normalized_name TEXT
    )''',
    '''
    CREATE TABLE IF NOT EXISTS card_prints (
      id TEXT PRIMARY KEY,
      card_id TEXT NOT NULL,
      face_id TEXT UNIQUE NOT NULL,
      set_code TEXT,
      art_type TEXT,
      orientation TEXT,
      layout_position INTEGER,
      is_canonical INTEGER NOT NULL DEFAULT 1,
      image_url TEXT,
      art_bbox TEXT,
      image_phash INTEGER,
      image_phash_full INTEGER,
      tcgplayer_url TEXT
    )''',
    'CREATE INDEX IF NOT EXISTS idx_prints_card ON card_prints(card_id)',
    'CREATE INDEX IF NOT EXISTS idx_prints_set ON card_prints(set_code)',
    'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)',
  ];

  static Future<CardDatabase> open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'cards.db');
    final versionFile = File('$path.version');

    final exists = await File(path).exists();
    final installedVersion =
        await versionFile.exists() ? await versionFile.readAsString() : null;

    if (!exists || installedVersion != bundledVersion) {
      final copied = await _copyAssetTo(path);
      if (copied) {
        await versionFile.writeAsString(bundledVersion);
      } else if (!exists) {
        // No bundled asset yet: create an empty schema database.
        final db = await openDatabase(path, version: 1,
            onCreate: (db, _) async {
          for (final stmt in schema) {
            await db.execute(stmt);
          }
        });
        return CardDatabase._(db);
      }
    }

    final db = await openDatabase(path, readOnly: false);
    return CardDatabase._(db);
  }

  /// Copies the asset DB to [path]. Returns false if the asset doesn't exist.
  static Future<bool> _copyAssetTo(String path) async {
    try {
      final data = await rootBundle.load(_assetPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await File(path).parent.create(recursive: true);
      await File(path).writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The content version stamped into the open DB's `meta` table by the builder
  /// (`tool/build_card_db.py` writes `meta.version`). This is the single source
  /// of truth for "which card data is installed" and is compared against the
  /// remote `manifest.card_db.version` to decide whether to pull a newer DB.
  /// Null when the meta row is absent (e.g. an empty-schema fallback DB).
  Future<String?> installedVersion() async {
    try {
      final rows = await db.query('meta',
          columns: ['value'], where: 'key = ?', whereArgs: ['version'], limit: 1);
      return rows.isEmpty ? null : rows.first['value'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Replaces the installed database with [bytes] (e.g. a freshly downloaded
  /// update) and reopens it. The remote-update flow uses this to swap in a newer
  /// `cards.db`; callers must then rebuild the [CardDao] against the returned
  /// handle (see `RemoteUpdateService`).
  Future<CardDatabase> replaceWith(List<int> bytes, String version) async {
    final path = db.path;
    await db.close();
    await File(path).writeAsBytes(bytes, flush: true);
    await File('$path.version').writeAsString(version);
    final reopened = await openDatabase(path);
    return CardDatabase._(reopened);
  }

  Future<void> close() => db.close();
}
