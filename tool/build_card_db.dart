// Builds the bundled `assets/cards.db` SQLite database used by the app for
// offline perceptual-hash card lookup.
//
// Data source: the fab-tabletop project's pre-curated card snapshots
// (`priv/cards/generated/cards-*.json`), which already include each print's
// name, set, image URL, art bounding box and orientation.
//
// By default the tool DOWNLOADS each card image and RECOMPUTES the perceptual
// hashes using the same Dart `PHash` code the app runs on-device — this is
// what keeps the precomputed hashes compatible with live camera captures.
// Pass `--reuse-phash` to instead copy the hashes already present in the JSON
// (faster, but only matches if the app uses an identical hash pipeline).
//
// Usage:
//   dart run tool/build_card_db.dart \
//       [--from <generated_dir>] [--out assets/cards.db] \
//       [--limit N] [--concurrency 8] [--reuse-phash]
//
// Example quick test (50 cards, recompute):
//   dart run tool/build_card_db.dart --limit 50

import 'dart:convert';
import 'dart:io';

import 'package:fabscan/src/models/fab_card.dart';
import 'package:fabscan/src/vision/art_crop.dart';
import 'package:fabscan/src/vision/phash.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:sqlite3/sqlite3.dart';

const _defaultGenerated =
    '/home/luke/Storage/Repositories/fab-tabletop/tabletop/priv/cards/generated';
const _defaultOut = 'assets/cards.db';

Future<void> main(List<String> args) async {
  final opts = _Options.parse(args);
  stdout.writeln('FabScan card DB builder');
  stdout.writeln('  source:      ${opts.fromDir}');
  stdout.writeln('  output:      ${opts.outPath}');
  stdout.writeln('  phash:       ${opts.reusePhash ? 'reuse from JSON' : 'recompute from images'}');
  if (opts.limit != null) stdout.writeln('  limit:       ${opts.limit}');

  final cards = _loadCards(opts.fromDir, opts.limit);
  stdout.writeln('Loaded ${cards.length} cards.');

  final out = File(opts.outPath);
  await out.parent.create(recursive: true);
  if (out.existsSync()) out.deleteSync();

  final db = sqlite3.open(opts.outPath);
  _createSchema(db);
  db.execute('INSERT INTO meta(key, value) VALUES (?, ?)',
      ['version', DateTime.now().toIso8601String()]);

  final client = http.Client();
  final insertCard =
      db.prepare('INSERT OR REPLACE INTO cards(id, name, pitch, normalized_name) VALUES (?,?,?,?)');
  final insertPrint = db.prepare('''
    INSERT OR REPLACE INTO card_prints
      (id, card_id, face_id, set_code, art_type, orientation, layout_position,
       is_canonical, image_url, art_bbox, image_phash, image_phash_full)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
  ''');

  var processed = 0;
  var hashed = 0;
  var failed = 0;

  db.execute('BEGIN');
  for (final card in cards) {
    final cardId = card.externalId;
    insertCard.execute([
      cardId,
      card.name,
      card.pitch,
      card.name.toLowerCase(),
    ]);

    // Recompute hashes for this card's prints (optionally concurrently).
    final hashesByFace = opts.reusePhash
        ? <String, _Hashes>{}
        : await _computeHashes(client, card.prints, opts.concurrency,
            onError: () => failed++);

    for (final pr in card.prints) {
      final h = opts.reusePhash
          ? _Hashes(pr.imagePhash, pr.imagePhashFull)
          : (hashesByFace[pr.faceId] ?? const _Hashes(null, null));
      if (h.art != null || h.full != null) hashed++;

      insertPrint.execute([
        pr.faceId, // print id == face_id (globally unique)
        cardId,
        pr.faceId,
        pr.setCode,
        pr.artType,
        pr.orientation,
        pr.layoutPosition,
        pr.isCanonical ? 1 : 0,
        pr.imageUrl,
        pr.artBbox == null ? null : jsonEncode(pr.artBbox!.toJson()),
        h.art,
        h.full,
      ]);
    }

    processed++;
    if (processed % 50 == 0) {
      stdout.writeln('  $processed/${cards.length} cards (hashed prints: $hashed, failures: $failed)');
    }
  }
  db.execute('COMMIT');

  insertCard.dispose();
  insertPrint.dispose();
  client.close();

  final cardRows = db.select('SELECT COUNT(*) c FROM cards').first['c'];
  final printRows = db.select('SELECT COUNT(*) c FROM card_prints').first['c'];
  db.dispose();

  stdout.writeln('Done. Wrote ${opts.outPath}');
  stdout.writeln('  cards:  $cardRows');
  stdout.writeln('  prints: $printRows (with hashes: $hashed, image failures: $failed)');
  stdout.writeln('\nNow ensure pubspec.yaml lists `assets/cards.db` and rebuild the app.');
}

void _createSchema(Database db) {
  db.execute('''
    CREATE TABLE cards (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      pitch INTEGER,
      normalized_name TEXT
    )''');
  db.execute('''
    CREATE TABLE card_prints (
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
      image_phash_full INTEGER
    )''');
  db.execute('CREATE INDEX idx_prints_card ON card_prints(card_id)');
  db.execute('CREATE INDEX idx_prints_set ON card_prints(set_code)');
  db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
}

/// Downloads + hashes a batch of prints with bounded concurrency.
Future<Map<String, _Hashes>> _computeHashes(
  http.Client client,
  List<_Print> prints,
  int concurrency, {
  required void Function() onError,
}) async {
  final result = <String, _Hashes>{};
  for (var i = 0; i < prints.length; i += concurrency) {
    final chunk = prints.skip(i).take(concurrency);
    final entries = await Future.wait(chunk.map((pr) async {
      try {
        final hashes = await _hashOnePrint(client, pr);
        return MapEntry(pr.faceId, hashes);
      } catch (_) {
        onError();
        return MapEntry(pr.faceId, const _Hashes(null, null));
      }
    }));
    result.addEntries(entries);
  }
  return result;
}

Future<_Hashes> _hashOnePrint(http.Client client, _Print pr) async {
  if (pr.imageUrl == null) return const _Hashes(null, null);
  final resp = await client
      .get(Uri.parse(pr.imageUrl!))
      .timeout(const Duration(seconds: 20));
  if (resp.statusCode != 200) {
    throw HttpException('HTTP ${resp.statusCode} for ${pr.imageUrl}');
  }
  final decoded = img.decodeImage(resp.bodyBytes);
  if (decoded == null) throw const FormatException('decode failed');
  final rgb = decoded.getBytes(order: img.ChannelOrder.rgb);
  final w = decoded.width;
  final h = decoded.height;

  final fullHash = PHash.compute(rgb, w, h, 3);
  // Use the SAME fixed crop the app uses at scan time (the app can't know the
  // print's art type from a camera frame), so the DB hash is comparable. This
  // is the single tuning knob — see ArtBbox.defaultRegular in fab_card.dart.
  final crop = ArtCrop.extract(rgb, w, h, ArtBbox.defaultRegular);
  final artHash = PHash.compute(crop.rgb, crop.width, crop.height, 3);

  return _Hashes(artHash, fullHash);
}

/// Reads and flattens the generated card JSON files.
List<_Card> _loadCards(String dir, int? limit) {
  final directory = Directory(dir);
  if (!directory.existsSync()) {
    stderr.writeln('Source directory not found: $dir');
    exit(1);
  }
  final files = directory
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final cards = <_Card>[];
  for (final file in files) {
    final data = jsonDecode(file.readAsStringSync());
    if (data is! List) continue;
    for (final entry in data) {
      cards.add(_Card.fromJson(entry as Map<String, Object?>));
      if (limit != null && cards.length >= limit) return cards;
    }
  }
  return cards;
}

class _Options {
  _Options({
    required this.fromDir,
    required this.outPath,
    required this.limit,
    required this.concurrency,
    required this.reusePhash,
  });

  final String fromDir;
  final String outPath;
  final int? limit;
  final int concurrency;
  final bool reusePhash;

  static _Options parse(List<String> args) {
    String? from;
    String? out;
    int? limit;
    var concurrency = 8;
    var reuse = false;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--from':
          from = args[++i];
        case '--out':
          out = args[++i];
        case '--limit':
          limit = int.parse(args[++i]);
        case '--concurrency':
          concurrency = int.parse(args[++i]);
        case '--reuse-phash':
          reuse = true;
        default:
          stderr.writeln('Unknown argument: ${args[i]}');
          exit(2);
      }
    }
    return _Options(
      fromDir: from ?? _defaultGenerated,
      outPath: out ?? _defaultOut,
      limit: limit,
      concurrency: concurrency,
      reusePhash: reuse,
    );
  }
}

class _Hashes {
  const _Hashes(this.art, this.full);
  final int? art;
  final int? full;
}

/// Minimal parse models for the generated JSON.
class _Card {
  _Card({
    required this.externalId,
    required this.name,
    required this.pitch,
    required this.prints,
  });

  final String externalId;
  final String name;
  final int? pitch;
  final List<_Print> prints;

  factory _Card.fromJson(Map<String, Object?> j) {
    final prints = (j['card_prints'] as List? ?? const [])
        .map((p) => _Print.fromJson(p as Map<String, Object?>))
        .toList();
    return _Card(
      externalId: (j['external_card_id'] as String?) ?? (j['name'] as String),
      name: j['name'] as String,
      pitch: (j['pitch'] as num?)?.toInt(),
      prints: prints,
    );
  }
}

class _Print {
  _Print({
    required this.faceId,
    required this.setCode,
    required this.artType,
    required this.orientation,
    required this.layoutPosition,
    required this.isCanonical,
    required this.imageUrl,
    required this.artBbox,
    required this.imagePhash,
    required this.imagePhashFull,
  });

  final String faceId;
  final String? setCode;
  final String? artType;
  final String? orientation;
  final int? layoutPosition;
  final bool isCanonical;
  final String? imageUrl;
  final ArtBbox? artBbox;
  final int? imagePhash;
  final int? imagePhashFull;

  factory _Print.fromJson(Map<String, Object?> j) {
    final bbox = j['art_bbox'];
    final hasBbox = bbox is Map &&
        bbox['x'] is num &&
        bbox['y'] is num &&
        bbox['w'] is num &&
        bbox['h'] is num;
    return _Print(
      faceId: j['face_id'] as String,
      setCode: j['set_code'] as String?,
      artType: j['art_type'] as String?,
      orientation: j['orientation'] as String?,
      layoutPosition: (j['layout_position'] as num?)?.toInt(),
      isCanonical: (j['is_canonical'] as bool?) ?? true,
      imageUrl: j['image_url'] as String?,
      artBbox: hasBbox ? ArtBbox.fromJson(bbox.cast<String, Object?>()) : null,
      imagePhash: j['image_phash'] as int?,
      imagePhashFull: j['image_phash_full'] as int?,
    );
  }
}
