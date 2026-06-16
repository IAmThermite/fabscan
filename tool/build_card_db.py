#!/usr/bin/env python3
"""Builds the bundled ``cards.db`` SQLite database used by the app for offline
perceptual-hash card lookup.

This is the Python port of the former ``tool/build_card_db.dart``. It runs both
locally (to refresh the bundled ``assets/cards.db`` before an app release) and in
CI (weekly / on demand) to publish a new ``cards.db`` for the app's remote-update
flow.

Data source: the ``flesh-and-blood-cards`` fork's ``json/english/card.json`` (the
``feature/card-art-hashes`` branch), which ships PRECOMPUTED perceptual hashes for
every printing. Each card carries its gameplay identity (name, pitch) at the top
level and a ``printings`` array; each printing carries ``phash_art`` /
``phash_full`` (stringified 63-bit ints), the image URL, set, foiling, edition and
art-variation codes. We read the hashes straight through — no image download, no
recompute.

IMPORTANT — keep in sync:
  * The schema below MUST stay byte-identical to ``CardDatabase.schema`` in
    ``lib/src/db/card_database.dart``.
  * The art crop the fork hashes against (``REGULAR_ART_BBOX``) must equal the
    app's ``ArtBbox.defaultRegular`` (0.10/0.16/0.80/0.42).

``meta.version`` is stamped with a content-derived string (``YYYY-MM-DD.<short
sha256 of card.json>``). The app compares this to the remote
``manifest.card_db.version`` to decide whether to pull a newer DB, so it changes
exactly when the card data changes.

Usage:
  python tool/build_card_db.py [--from <card.json|url>] [--out assets/cards.db]
                               [--limit N] [--print-version]
"""

import argparse
import datetime as _dt
import hashlib
import json
import os
import sqlite3
import sys
import urllib.request

DEFAULT_CARD_JSON = "flesh-and-blood-cards/json/english/card.json"
DEFAULT_OUT = "assets/cards.db"

# Art-variation codes -> kebab-case label consumed by CardPrint.variantLabel.
# No variations means the base print; we tag it "regular" (hidden in the UI).
_ART_VARIATION_NAMES = {
    "AB": "alternate-border",
    "AA": "alternate-art",
    "AT": "alternate-text",
    "EA": "extended-art",
    "FA": "full-art",
    "HS": "half-size",
}


def _art_type_from(variations):
    if not variations:
        return "regular"
    return " ".join(_ART_VARIATION_NAMES.get(v, v.lower()) for v in variations)


def _parse_hash(raw):
    """Stringified phash -> int, or None when absent/empty."""
    if isinstance(raw, int):
        return raw
    if isinstance(raw, str):
        t = raw.strip()
        if not t:
            return None
        try:
            return int(t)
        except ValueError:
            return None
    return None


def _parse_pitch(raw):
    """Pitch ships as a string: '', '1', '2', '3'."""
    if raw is None:
        return None
    try:
        return int(str(raw).strip())
    except ValueError:
        return None


def _read_source(path_or_url):
    if path_or_url.startswith("http://") or path_or_url.startswith("https://"):
        with urllib.request.urlopen(path_or_url, timeout=60) as resp:  # noqa: S310
            return resp.read()
    with open(path_or_url, "rb") as f:
        return f.read()


def _content_version(raw_bytes):
    short = hashlib.sha256(raw_bytes).hexdigest()[:8]
    day = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
    return f"{day}.{short}"


def _create_schema(db):
    # Keep identical to CardDatabase.schema in lib/src/db/card_database.dart.
    db.execute(
        """
        CREATE TABLE cards (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          pitch INTEGER,
          normalized_name TEXT
        )"""
    )
    db.execute(
        """
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
        )"""
    )
    db.execute("CREATE INDEX idx_prints_card ON card_prints(card_id)")
    db.execute("CREATE INDEX idx_prints_set ON card_prints(set_code)")
    db.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")


def _empty_to_none(s):
    if s is None:
        return None
    s = s.strip()
    return s or None


def build(card_json_path, out_path, limit=None):
    raw = _read_source(card_json_path)
    version = _content_version(raw)
    data = json.loads(raw)
    if not isinstance(data, list):
        sys.stderr.write(f"Expected a JSON array at {card_json_path}\n")
        sys.exit(1)
    if limit is not None:
        data = data[:limit]

    print("FabScan card DB builder (python)")
    print(f"  source:  {card_json_path}")
    print(f"  output:  {out_path}")
    print(f"  version: {version}")
    if limit is not None:
        print(f"  limit:   {limit}")
    print(f"Loaded {len(data)} cards.")

    out_dir = os.path.dirname(os.path.abspath(out_path))
    os.makedirs(out_dir, exist_ok=True)
    if os.path.exists(out_path):
        os.remove(out_path)

    db = sqlite3.connect(out_path)
    try:
        _create_schema(db)
        db.execute("INSERT INTO meta(key, value) VALUES (?, ?)", ("version", version))

        hashed = 0
        unhashed = 0
        for card in data:
            card_id = card["unique_id"]
            name = card["name"]
            pitch = _parse_pitch(card.get("pitch"))
            orientation = "horizontal" if card.get("played_horizontally") else "vertical"

            db.execute(
                "INSERT OR REPLACE INTO cards(id, name, pitch, normalized_name) "
                "VALUES (?,?,?,?)",
                (card_id, name, pitch, name.lower()),
            )

            printings = card.get("printings") or []
            for i, pr in enumerate(printings):
                variations = pr.get("art_variations") or []
                art_phash = _parse_hash(pr.get("phash_art"))
                full_phash = _parse_hash(pr.get("phash_full"))
                if art_phash is not None or full_phash is not None:
                    hashed += 1
                else:
                    unhashed += 1

                db.execute(
                    """INSERT OR REPLACE INTO card_prints
                       (id, card_id, face_id, set_code, art_type, orientation,
                        layout_position, is_canonical, image_url, art_bbox,
                        image_phash, image_phash_full, tcgplayer_url)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (
                        pr["unique_id"],
                        card_id,
                        pr["unique_id"],  # face_id == print id
                        pr.get("set_id"),
                        _art_type_from(variations),
                        orientation,
                        i,  # layout_position
                        1 if i == 0 else 0,  # first printing is canonical
                        _empty_to_none(pr.get("image_url")),
                        None,  # art_bbox: app crops with the fixed ArtBbox.defaultRegular
                        art_phash,
                        full_phash,
                        _empty_to_none(pr.get("tcgplayer_url")),
                    ),
                )

        db.commit()

        card_rows = db.execute("SELECT COUNT(*) FROM cards").fetchone()[0]
        print_rows = db.execute("SELECT COUNT(*) FROM card_prints").fetchone()[0]
    finally:
        db.close()

    # Sidecar consumed by tool/build_manifest.py for the remote-update version.
    with open(out_path + ".version", "w", encoding="utf-8") as f:
        f.write(version)

    print(f"Done. Wrote {out_path}")
    print(f"  cards:  {card_rows}")
    print(f"  prints: {print_rows} (with hashes: {hashed}, without: {unhashed})")
    return version


def main(argv):
    ap = argparse.ArgumentParser(description="Build the bundled cards.db")
    ap.add_argument("--from", dest="src", default=DEFAULT_CARD_JSON,
                    help="card.json path or URL")
    ap.add_argument("--out", dest="out", default=DEFAULT_OUT)
    ap.add_argument("--limit", dest="limit", type=int, default=None)
    ap.add_argument("--print-version", action="store_true",
                    help="only print the content version that WOULD be built")
    args = ap.parse_args(argv)

    if args.print_version:
        print(_content_version(_read_source(args.src)))
        return
    build(args.src, args.out, args.limit)


if __name__ == "__main__":
    main(sys.argv[1:])
