# FabScan

Point your phone at a **Flesh and Blood** trading card and instantly see the
card, its set / foil / art variants, and prices from third-party sites.

Everything except pricing runs **offline** against a bundled SQLite database of
precomputed perceptual hashes. The only network calls are to the pricing
sources (and, later, to fetch a fresh card database).

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
| [lib/src/pricing/](lib/src/pricing/) | Pluggable price sources (Shopify live fetch + link-outs) |
| [lib/src/ui/](lib/src/ui/) | Scan screen, results + variant carousel, recents |
| [tool/build_card_db.dart](tool/build_card_db.dart) | Generates `assets/cards.db` |

## Setup

```bash
flutter pub get
flutter run            # on a connected Android device
```

On the **first Android build**, `opencv_dart` downloads the OpenCV SDK (~100 MB)
via CMake — expect a slow first compile. `assets/tessdata/eng.traineddata`
(Tesseract English data) is already bundled.

### Building the card database

`assets/cards.db` is generated from the `fab-tabletop` card snapshots. The
hashes must be produced by the **same Dart pipeline** the app runs on-device, so
the default mode downloads each card image and recomputes them:

```bash
# Full database (downloads ~9k card images; one-time, several minutes)
dart run tool/build_card_db.dart

# Quick test against 50 cards
dart run tool/build_card_db.dart --limit 50

# Fast path: reuse the hashes already in the JSON (NOTE: these were computed by
# the reference project's pipeline and will NOT match live camera hashes — use
# only for populating names/images/variants while developing the UI).
dart run tool/build_card_db.dart --reuse-phash
```

Output goes to `assets/cards.db` by default (`--out` to change). If the asset is
missing the app still launches with an empty database (no matches).

## Pricing sources

Pricing is pluggable via [`PriceSource`](lib/src/pricing/price_source.dart):

- **MinMaxGames**, **Fluke & Box** — Shopify storefronts; live prices are
  fetched from their public `/search/suggest.json` endpoint (no API key).
- **TCGplayer**, **Cardmarket** — no open price API, so these deep-link to the
  site's search results.

Add a new store by implementing `PriceSource` (or extending `ShopifySource`)
and registering it in [`PricingService`](lib/src/pricing/pricing_service.dart).

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
