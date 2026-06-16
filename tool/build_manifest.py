#!/usr/bin/env python3
"""Regenerates ``manifest.json`` from whatever data files are present in the
publish directory.

The app fetches this tiny file on every launch to decide what to pull:
  * ``prices``  -> downloaded by the app when stale (>24h) AND ``generated_at``
                   has changed.
  * ``card_db`` -> pulled whenever ``version`` differs from the installed DB.

Because the price job (daily) and the card-DB job (weekly/on-demand) run on
different schedules, each one checks out the existing published files into the
publish dir, rebuilds only its own artifact, then regenerates the manifest from
*all* files present — so the section it didn't touch is preserved.

Usage:
  python tool/build_manifest.py --dir public --base-url https://iamthermite.github.io/fabscan
"""

import argparse
import json
import os
import sys

SCHEMA_VERSION = 1
DEFAULT_BASE_URL = "https://iamthermite.github.io/fabscan"


def build_manifest(dist_dir, base_url):
    base = base_url.rstrip("/")
    manifest = {"schema_version": SCHEMA_VERSION}

    prices_path = os.path.join(dist_dir, "prices.json")
    if os.path.exists(prices_path):
        try:
            with open(prices_path, encoding="utf-8") as f:
                generated_at = json.load(f).get("generated_at")
            if generated_at:
                manifest["prices"] = {
                    "url": f"{base}/prices.json",
                    "generated_at": generated_at,
                }
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[manifest] could not read prices.json: {e}\n")

    db_path = os.path.join(dist_dir, "cards.db")
    version_path = db_path + ".version"
    if os.path.exists(db_path) and os.path.exists(version_path):
        try:
            with open(version_path, encoding="utf-8") as f:
                version = f.read().strip()
            if version:
                manifest["card_db"] = {
                    "url": f"{base}/cards.db",
                    "version": version,
                }
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[manifest] could not read cards.db.version: {e}\n")

    return manifest


def main(argv):
    ap = argparse.ArgumentParser(description="Regenerate manifest.json")
    ap.add_argument("--dir", dest="dir", default="public")
    ap.add_argument("--base-url", dest="base_url", default=DEFAULT_BASE_URL)
    args = ap.parse_args(argv)

    manifest = build_manifest(args.dir, args.base_url)
    out_path = os.path.join(args.dir, "manifest.json")
    os.makedirs(args.dir, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    sys.stderr.write(f"Wrote {out_path}: {json.dumps(manifest)}\n")


if __name__ == "__main__":
    main(sys.argv[1:])
