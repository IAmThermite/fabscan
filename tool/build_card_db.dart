// Builds the bundled `assets/cards.db` SQLite database used by the app for
// offline perceptual-hash card lookup.
//
// Data source: the `flesh-and-blood-cards` submodule
// (`flesh-and-blood-cards/json/english/card.json`), a fork that ships
// PRECOMPUTED perceptual hashes for every printing. Each card carries its
// gameplay identity (name, pitch) at the top level and a `printings` array;
// each printing carries `phash_art` / `phash_full` (stringified 63-bit ints),
// the image URL, set, foiling, edition and art-variation codes.
//
// Those hashes are computed by the fork's `helper-scripts/calculate-phashes`
// tool, whose pipeline is byte-for-byte equivalent to this app's Dart `PHash`
// (same 32x32 area-average downsample, 0.299/0.587/0.114 luma, top-left 8x8
// DCT block with the DC term excluded, and the regular art rect
// 0.10/0.16/0.80/0.42 == `ArtBbox.defaultRegular`). So we read the hashes
// straight from the JSON — no image download, no recompute.
//
// Usage:
//   dart run tool/build_card_db.dart \
//       [--from <card.json>] [--out assets/cards.db] [--limit N]
//
// Quick test (first 50 cards):
//   dart run tool/build_card_db.dart --limit 50

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

const _defaultCardJson = 'flesh-and-blood-cards/json/english/card.json';
const _defaultOut = 'assets/cards.db';

Future<void> main(List<String> args) async {
  final opts = _Options.parse(args);
  stdout.writeln('FabScan card DB builder');
  stdout.writeln('  source:      ${opts.cardJsonPath}');
  stdout.writeln('  output:      ${opts.outPath}');
  if (opts.limit != null) stdout.writeln('  limit:       ${opts.limit}');

  final cards = _loadCards(opts.cardJsonPath, opts.limit);
  stdout.writeln('Loaded ${cards.length} cards.');

  final out = File(opts.outPath);
  await out.parent.create(recursive: true);
  if (out.existsSync()) out.deleteSync();

  final db = sqlite3.open(opts.outPath);
  _createSchema(db);
  db.execute('INSERT INTO meta(key, value) VALUES (?, ?)',
      ['version', DateTime.now().toIso8601String()]);

  final insertCard = db.prepare(
      'INSERT OR REPLACE INTO cards(id, name, pitch, normalized_name) VALUES (?,?,?,?)');
  final insertPrint = db.prepare('''
    INSERT OR REPLACE INTO card_prints
      (id, card_id, face_id, set_code, art_type, orientation, layout_position,
       is_canonical, image_url, art_bbox, image_phash, image_phash_full,
       tcgplayer_url)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
  ''');

  var processed = 0;
  var hashedPrints = 0;
  var unhashedPrints = 0;

  db.execute('BEGIN');
  for (final card in cards) {
    insertCard.execute([
      card.id,
      card.name,
      card.pitch,
      card.name.toLowerCase(),
    ]);

    for (var i = 0; i < card.prints.length; i++) {
      final pr = card.prints[i];
      if (pr.artPhash != null || pr.fullPhash != null) {
        hashedPrints++;
      } else {
        unhashedPrints++;
      }

      insertPrint.execute([
        pr.id, // printing unique_id (globally unique)
        card.id,
        pr.id, // face_id == print id (kept for schema compatibility)
        pr.setCode,
        pr.artType,
        card.orientation,
        i, // layout_position: order within the card's printings
        i == 0 ? 1 : 0, // first printing is the canonical/default one to show
        pr.imageUrl,
        null, // art_bbox: the app crops with the fixed ArtBbox.defaultRegular
        pr.artPhash,
        pr.fullPhash,
        pr.tcgplayerUrl,
      ]);
    }

    processed++;
    if (processed % 500 == 0) {
      stdout.writeln('  $processed/${cards.length} cards '
          '(hashed prints: $hashedPrints, no-hash: $unhashedPrints)');
    }
  }
  db.execute('COMMIT');

  insertCard.dispose();
  insertPrint.dispose();

  final cardRows = db.select('SELECT COUNT(*) c FROM cards').first['c'];
  final printRows = db.select('SELECT COUNT(*) c FROM card_prints').first['c'];
  db.dispose();

  stdout.writeln('Done. Wrote ${opts.outPath}');
  stdout.writeln('  cards:  $cardRows');
  stdout.writeln('  prints: $printRows '
      '(with hashes: $hashedPrints, without: $unhashedPrints)');
  stdout.writeln('\nNow bump CardDatabase.bundledVersion, ensure pubspec.yaml '
      'lists `assets/cards.db`, and rebuild the app.');
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
      image_phash_full INTEGER,
      tcgplayer_url TEXT
    )''');
  db.execute('CREATE INDEX idx_prints_card ON card_prints(card_id)');
  db.execute('CREATE INDEX idx_prints_set ON card_prints(set_code)');
  db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
}

/// Reads and parses the `card.json` array from the submodule.
List<_Card> _loadCards(String path, int? limit) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Card JSON not found: $path');
    stderr.writeln('Did you init the submodule? '
        'git submodule update --init flesh-and-blood-cards');
    exit(1);
  }
  final data = jsonDecode(file.readAsStringSync());
  if (data is! List) {
    stderr.writeln('Expected a JSON array at $path');
    exit(1);
  }
  final cards = <_Card>[];
  for (final entry in data) {
    cards.add(_Card.fromJson(entry as Map<String, Object?>));
    if (limit != null && cards.length >= limit) break;
  }
  return cards;
}

class _Options {
  _Options({required this.cardJsonPath, required this.outPath, required this.limit});

  final String cardJsonPath;
  final String outPath;
  final int? limit;

  static _Options parse(List<String> args) {
    String? from;
    String? out;
    int? limit;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--from':
          from = args[++i];
        case '--out':
          out = args[++i];
        case '--limit':
          limit = int.parse(args[++i]);
        default:
          stderr.writeln('Unknown argument: ${args[i]}');
          exit(2);
      }
    }
    return _Options(
      cardJsonPath: from ?? _defaultCardJson,
      outPath: out ?? _defaultOut,
      limit: limit,
    );
  }
}

/// Minimal parse models for the flesh-and-blood-cards `card.json`.
class _Card {
  _Card({
    required this.id,
    required this.name,
    required this.pitch,
    required this.orientation,
    required this.prints,
  });

  final String id;
  final String name;
  final int? pitch;
  final String orientation; // "horizontal" | "vertical"
  final List<_Print> prints;

  factory _Card.fromJson(Map<String, Object?> j) {
    final prints = (j['printings'] as List? ?? const [])
        .map((p) => _Print.fromJson(p as Map<String, Object?>))
        .toList();
    final playedHorizontally = (j['played_horizontally'] as bool?) ?? false;
    return _Card(
      id: j['unique_id'] as String,
      name: j['name'] as String,
      // pitch ships as a string: '', '1', '2', '3'.
      pitch: int.tryParse((j['pitch'] as String?)?.trim() ?? ''),
      orientation: playedHorizontally ? 'horizontal' : 'vertical',
      prints: prints,
    );
  }
}

class _Print {
  _Print({
    required this.id,
    required this.setCode,
    required this.artType,
    required this.imageUrl,
    required this.artPhash,
    required this.fullPhash,
    required this.tcgplayerUrl,
  });

  final String id;
  final String? setCode;
  final String? artType;
  final String? imageUrl;
  final int? artPhash;
  final int? fullPhash;
  final String? tcgplayerUrl;

  factory _Print.fromJson(Map<String, Object?> j) {
    final variations = (j['art_variations'] as List? ?? const [])
        .map((v) => v as String)
        .toList();
    return _Print(
      id: j['unique_id'] as String,
      setCode: j['set_id'] as String?,
      artType: _artTypeFrom(variations),
      imageUrl: (j['image_url'] as String?)?.trim().isEmpty ?? true
          ? null
          : j['image_url'] as String?,
      artPhash: _parseHash(j['phash_art']),
      fullPhash: _parseHash(j['phash_full']),
      tcgplayerUrl: (j['tcgplayer_url'] as String?)?.trim().isEmpty ?? true
          ? null
          : j['tcgplayer_url'] as String?,
    );
  }
}

// Art-variation codes -> kebab-case label consumed by CardPrint.variantLabel.
// No variations means the base print; we tag it "regular" (hidden in the UI).
const _artVariationNames = {
  'AB': 'alternate-border',
  'AA': 'alternate-art',
  'AT': 'alternate-text',
  'EA': 'extended-art',
  'FA': 'full-art',
  'HS': 'half-size',
};

String _artTypeFrom(List<String> variations) {
  if (variations.isEmpty) return 'regular';
  return variations.map((v) => _artVariationNames[v] ?? v.toLowerCase()).join(' ');
}

/// Parses a stringified phash to an int, or null when absent/empty.
int? _parseHash(Object? raw) {
  if (raw is int) return raw;
  if (raw is String) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t);
  }
  return null;
}
