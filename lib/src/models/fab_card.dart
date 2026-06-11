import 'dart:convert';

/// A logical Flesh and Blood card (gameplay identity: name + pitch).
///
/// Mirrors the `cards` table in the bundled SQLite database. A single
/// [FabCard] owns one or more [CardPrint]s representing the physical
/// printings (set variants, foils, extended/full art, etc.).
class FabCard {
  const FabCard({
    required this.id,
    required this.name,
    this.pitch,
    this.normalizedName,
    this.prints = const [],
  });

  final String id;
  final String name;
  final int? pitch;
  final String? normalizedName;
  final List<CardPrint> prints;

  /// The print to show first: the canonical one, else the first available.
  CardPrint? get canonicalPrint {
    if (prints.isEmpty) return null;
    return prints.firstWhere(
      (p) => p.isCanonical,
      orElse: () => prints.first,
    );
  }

  factory FabCard.fromMap(Map<String, Object?> map,
      {List<CardPrint> prints = const []}) {
    return FabCard(
      id: map['id'] as String,
      name: map['name'] as String,
      pitch: map['pitch'] as int?,
      normalizedName: map['normalized_name'] as String?,
      prints: prints,
    );
  }

  FabCard copyWith({List<CardPrint>? prints}) => FabCard(
        id: id,
        name: name,
        pitch: pitch,
        normalizedName: normalizedName,
        prints: prints ?? this.prints,
      );
}

/// A physical printing of a [FabCard]. Carries the image URL, the art
/// bounding box and the precomputed perceptual hashes used for matching.
class CardPrint {
  const CardPrint({
    required this.id,
    required this.cardId,
    required this.faceId,
    this.setCode,
    this.artType,
    this.orientation,
    this.layoutPosition,
    this.isCanonical = true,
    this.imageUrl,
    this.artBbox,
    this.imagePhash,
    this.imagePhashFull,
    this.tcgplayerUrl,
  });

  final String id;
  final String cardId;
  final String faceId;
  final String? setCode;

  /// e.g. "regular", "extended-art", "full-art", "marvel".
  final String? artType;

  /// "vertical" or "horizontal".
  final String? orientation;
  final int? layoutPosition;
  final bool isCanonical;
  final String? imageUrl;

  /// Art crop ratios `{x, y, w, h}` (0..1) within the upright card.
  final ArtBbox? artBbox;

  final int? imagePhash;
  final int? imagePhashFull;

  /// Deep link to this exact printing's TCGplayer product page, when known.
  /// Null for prints with no TCGplayer listing — callers fall back to search.
  final String? tcgplayerUrl;

  bool get isHorizontal => orientation == 'horizontal';

  /// Human-friendly variant label, e.g. "WTR · Extended Art".
  String get variantLabel {
    final parts = <String>[
      ?setCode,
      if (artType != null && artType != 'regular') _prettyArtType(artType!),
    ];
    return parts.isEmpty ? faceId : parts.join(' · ');
  }

  static String _prettyArtType(String t) => t
      .split('-')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  factory CardPrint.fromMap(Map<String, Object?> map) {
    final bboxRaw = map['art_bbox'] as String?;
    return CardPrint(
      id: map['id'] as String,
      cardId: map['card_id'] as String,
      faceId: map['face_id'] as String,
      setCode: map['set_code'] as String?,
      artType: map['art_type'] as String?,
      orientation: map['orientation'] as String?,
      layoutPosition: map['layout_position'] as int?,
      isCanonical: (map['is_canonical'] as int? ?? 1) == 1,
      imageUrl: map['image_url'] as String?,
      artBbox: bboxRaw == null
          ? null
          : ArtBbox.fromJson(jsonDecode(bboxRaw) as Map<String, Object?>),
      imagePhash: map['image_phash'] as int?,
      imagePhashFull: map['image_phash_full'] as int?,
      tcgplayerUrl: map['tcgplayer_url'] as String?,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'card_id': cardId,
        'face_id': faceId,
        'set_code': setCode,
        'art_type': artType,
        'orientation': orientation,
        'layout_position': layoutPosition,
        'is_canonical': isCanonical ? 1 : 0,
        'image_url': imageUrl,
        'art_bbox': artBbox == null ? null : jsonEncode(artBbox!.toJson()),
        'image_phash': imagePhash,
        'image_phash_full': imagePhashFull,
        'tcgplayer_url': tcgplayerUrl,
      };
}

/// Art crop expressed as ratios (0..1) of the upright card dimensions.
class ArtBbox {
  const ArtBbox({required this.x, required this.y, required this.w, required this.h});

  final double x;
  final double y;
  final double w;
  final double h;

  /// THE art-capture region used for pHash matching, as ratios of the upright
  /// card (x, y = top-left corner; w, h = size; all 0..1).
  ///
  /// This is the single knob for tuning the art crop. It is used in two places
  /// that MUST stay in sync:
  ///   * on-device at scan time ([CardDetector] crops the deskewed card here),
  ///   * in `tool/build_card_db.dart` when precomputing the bundled hashes.
  ///
  /// If you change it, you MUST rebuild the database so the stored hashes use
  /// the same region, otherwise nothing will match:
  ///   dart run tool/build_card_db.dart
  ///
  /// Current value (from the reference scanner): a window 80% of the card wide
  /// and 42% tall, starting 10% in from the left and 16% down from the top.
  /// To capture a larger area, widen w/h and/or move x/y toward 0 — e.g.
  /// ArtBbox(x: 0.06, y: 0.12, w: 0.88, h: 0.52).
  static const ArtBbox defaultRegular = ArtBbox(x: 0.10, y: 0.16, w: 0.80, h: 0.42);

  factory ArtBbox.fromJson(Map<String, Object?> j) => ArtBbox(
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        w: (j['w'] as num).toDouble(),
        h: (j['h'] as num).toDouble(),
      );

  Map<String, Object?> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};
}
