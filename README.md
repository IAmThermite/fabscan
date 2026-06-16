# FabScan

Point your phone at a **Flesh and Blood** trading card and instantly see the
card, its set / foil / art variants, and prices from third-party sites.

Scanning runs **offline** against a bundled SQLite database of precomputed
perceptual hashes, and prices are served from a locally cached dataset. Network
is only used at launch to check a small `manifest.json` and, when newer data is
available, pull a fresh prices dataset (≤1×/24h) or card database in the
background — the app works fully offline otherwise.

## How a scan works

```
camera frame ──► OpenCV: find card edges, deskew to an upright card
              ──► crop the art region, compute a 64-bit perceptual hash (pHash)
              ──► Tesseract: read the title bar (disambiguation aid)
              ──► look up the pHash in the bundled SQLite DB (Hamming distance)
              ──► show the card + variants ──► fetch prices ──► save to recents (24h)
```

The vision pipeline is a Dart port of the proven scanner in the `fab-tabletop`
project (same edge-detection strategies, art bbox ratios, DCT pHash and Hamming
thresholds — 15 for art crops, 8 for the whole-card hash).

## Project layout

| Path | Purpose |
|------|---------|
| [lib/src/vision/phash.dart](lib/src/vision/phash.dart) | 32×32 DCT → 64-bit perceptual hash (shared by app + build tool) |
| [lib/src/vision/card_detector.dart](lib/src/vision/card_detector.dart) | OpenCV contour detection + perspective deskew (`opencv_dart`) |
| [lib/src/vision/ocr_service.dart](lib/src/vision/ocr_service.dart) | Tesseract title OCR (`flutter_tesseract_ocr`) |
| [lib/src/vision/camera_utils.dart](lib/src/vision/camera_utils.dart) | YUV420 camera frame → BGR `Mat` |
| [lib/src/db/](lib/src/db/) | Bundled card DB loader, pHash matching DAO, 24h recents store |
| [lib/src/scan/scan_controller.dart](lib/src/scan/scan_controller.dart) | Frame sampling + recognition orchestration |
| [lib/src/pricing/](lib/src/pricing/) | Store-backed pricing (precomputed dataset + currency conversion + link-out fallback) |
| [lib/src/data/remote_update_service.dart](lib/src/data/remote_update_service.dart) | Launch-time `manifest.json` check → refresh prices / hot-swap card DB |
| [lib/src/ui/](lib/src/ui/) | Scan screen, results + variant carousel, recents |
| [tool/build_card_db.py](tool/build_card_db.py) | Builds `assets/cards.db` from the card-data submodule |
| [tool/scrape_prices.py](tool/scrape_prices.py) | Scrapes `prices.json` (prices + FX) for the app to download |
| [tool/build_manifest.py](tool/build_manifest.py) | Generates `manifest.json` (the launch-time update check) |

## Build & install

Prerequisites: **Flutter SDK** (`flutter doctor` should be green), and an
Android device/emulator or — for iOS — a Mac with Xcode + CocoaPods.

On the **first Android build**, `opencv_dart` downloads the OpenCV SDK (~100 MB)
via CMake, so expect a slow first compile. `assets/tessdata/eng.traineddata`
(Tesseract English data) is already bundled.

### Dev (debug, hot reload)

```bash
flutter pub get
flutter devices              # confirm a device/emulator is attached
flutter run                  # debug build, deploy, attach for hot reload
```

Press `r` for hot reload, `R` for hot restart. Splash and launcher-icon changes
are **native** resources — they need a full stop + `flutter run` to take effect.

### Release — Android

```bash
flutter build apk --release                 # universal APK
flutter build apk --release --split-per-abi # smaller per-ABI APKs
flutter build appbundle --release           # .aab for Google Play
```

Outputs:

| Artifact | Path |
|----------|------|
| Universal APK | `build/app/outputs/flutter-apk/app-release.apk` |
| Per-ABI APKs  | `build/app/outputs/flutter-apk/app-{armeabi-v7a,arm64-v8a,x86_64}-release.apk` |
| App bundle    | `build/app/outputs/bundle/release/app-release.aab` |

Install a built APK to a connected device:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
# or, build + install in one step on the connected device:
flutter install --release
```

> ⚠️ **Release is debug-signed.** [android/app/build.gradle.kts](android/app/build.gradle.kts)
> uses the debug keystore for the `release` build type so `flutter run --release`
> works locally. Before publishing, add a real `signingConfig` and set a unique
> `applicationId` (currently `com.example.fabscan`).

### Release — iOS (Mac only)

iOS can't be built from Linux; you need macOS + Xcode + CocoaPods. From a Mac:

```bash
flutter pub get
cd ios && pod install && cd ..   # auto-runs on the first flutter ios build
flutter build ipa --release      # archive + export an .ipa via Xcode
# or for a quick run on a connected device / simulator:
flutter run --release
```

The first iOS build on a fresh checkout will generate `ios/Podfile`. Before
release, set a real bundle identifier (currently `com.example.fabscan`) in
Xcode and remember the manual **OCR tessdata** step described in
[CLAUDE.md](CLAUDE.md#ios) (drag `assets/tessdata` into the Runner target as a
folder reference).

### Regenerating launcher icon & splash

If you change `assets/icon.png` or `assets/splash.png` (config lives in
[pubspec.yaml](pubspec.yaml)):

```bash
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

These rewrite native resources, so after running them: stop the app,
`adb uninstall com.example.fabscan` (Android caches launcher icons), then
`flutter run` again.

### Building the card database

`assets/cards.db` is built by [tool/build_card_db.py](tool/build_card_db.py)
(Python stdlib, no extra deps) from the **`flesh-and-blood-cards`** submodule,
which ships **precomputed** perceptual hashes — so there's no image download and
no recompute (it's fast). Init the submodule first:

```bash
git submodule update --init flesh-and-blood-cards   # one-time

# Full database (reads the submodule's card.json)
python tool/build_card_db.py --out assets/cards.db

# Quick test against 50 cards (writes elsewhere so you don't clobber the asset)
python tool/build_card_db.py --out /tmp/cards.db --limit 50

# You can also read card.json straight from the fork without the submodule:
python tool/build_card_db.py \
  --from https://raw.githubusercontent.com/IAmThermite/flesh-and-blood-cards/feature/card-art-hashes/json/english/card.json \
  --out /tmp/cards.db --limit 50
```

The builder stamps a content version into `meta.version` (used by the remote-DB
update check). If the asset is missing the app still launches with an empty
database (no matches). The submodule's hash pipeline must stay byte-compatible
with the app's `PHash` — see [CLAUDE.md](CLAUDE.md) before changing branches.

### Price & manifest data pipeline (local testing)

Prices are **precomputed** by [tool/scrape_prices.py](tool/scrape_prices.py) and
published (with a tiny [tool/build_manifest.py](tool/build_manifest.py)) for the
app to download — see [the data-pipeline section in CLAUDE.md](CLAUDE.md). To run
them locally:

```bash
pip install requests          # scrape_prices.py's only extra dep
                              # (build_card_db.py / build_manifest.py are stdlib-only)

# Scrape a handful of cards into ./dist/prices.json. --from takes a path or URL;
# use the raw fork URL to skip needing the submodule:
python tool/scrape_prices.py \
  --from https://raw.githubusercontent.com/IAmThermite/flesh-and-blood-cards/feature/card-art-hashes/json/english/card.json \
  --out dist --limit 50

# Iterate on one source at a time (skip the slow/best-effort ones):
python tool/scrape_prices.py --from <card.json|url> --out dist --limit 50 --no-tcg --no-cm

# Regenerate the manifest from whatever's in ./dist (prices.json and/or cards.db):
python tool/build_manifest.py --dir dist --base-url https://iamthermite.github.io/fabscan

# Inspect results:
cat dist/manifest.json
python -m json.tool dist/prices.json | head -40
```

Notes:
- Per-source coverage is logged to stderr (Shopify + TCGplayer cover many prints;
  Cardmarket is best-effort and usually empty → the app link-outs).
- The per-source keys in `prices.json` (`MinMaxGames`, `Fluke & Box`, `TCGplayer`,
  `Cardmarket`) must byte-match the app's `PriceSource.name` values, or that
  source silently downgrades to a link-out in the app.
- To exercise the app against a local file, host `dist/` (e.g.
  `python -m http.server` in `dist/`) and point `RemoteUpdateService`'s manifest
  URL at it.

## Pricing sources

Prices are **precomputed daily** by [tool/scrape_prices.py](tool/scrape_prices.py)
into a `prices.json` the app downloads (≤1×/24h) and serves offline from a local
`prices.db`, converted to the user's display currency (default NZD) at view time:

- **MinMaxGames** (AUD), **Fluke & Box** (NZD) — Shopify storefronts; the scraper
  bulk-crawls each store's public `/products.json`.
- **TCGplayer** (USD) — per-print, via the product id in each print's
  `tcgplayer_url` + TCGplayer's `mpapi` price-points endpoint.
- **Cardmarket** (EUR) — best-effort; usually degrades to a link-out.

Every source **always** offers at least a tappable link-out via
[`PriceSource`](lib/src/pricing/price_source.dart) (even offline / for unpriced
prints). Add a new store by implementing `PriceSource` (or extending
`ShopifySource`), registering it in
[`PricingService`](lib/src/pricing/pricing_service.dart), and adding a matching
adapter in `tool/scrape_prices.py` (keys must match `PriceSource.name`). See
[CLAUDE.md](CLAUDE.md) for the full pricing + remote-update design.

## Known limitations / next steps

- **Native build unverified end-to-end here** — Dart compiles, analyzer is clean
  and unit tests pass; the OpenCV/Tesseract native build should be run on-device.
- Per-frame detection runs on the main isolate (throttled). Moving it to an
  isolate is a follow-up (FFI `Mat`s don't cross isolates trivially).
- Horizontal-layout cards use only the whole-card hash for now; the left/right
  half hashes aren't recomputed by the tool yet.
- The live overlay's frame→preview mapping is best-effort and may need tuning
  per device orientation.
- Set a real `applicationId` (currently `com.example.fabscan`) before release.
