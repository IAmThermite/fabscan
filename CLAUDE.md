# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

FabScan is a Flutter app (**Android and iOS**) that scans Flesh and Blood trading cards
with the camera and shows the card, its set/foil/art variants, and third-party prices.
Android is the primary, build-verified target; iOS is supported but must be built and
tested on a Mac (see the iOS section below). Everything
except pricing runs offline against a bundled SQLite database of precomputed perceptual
hashes. The vision pipeline is a Dart port of the `fab-tabletop` reference scanner at
`/home/luke/Storage/Repositories/fab-tabletop/` (see `tabletop/assets/js/card_scanner/`).

## Commands

```bash
flutter pub get                       # install deps
flutter run                           # run on a connected Android device
flutter analyze                       # lint (flutter_lints; keep clean)
flutter test                          # all tests
flutter test test/phash_test.dart     # a single test file
flutter test --name "substring"       # a single test by name

# Rebuild the bundled card DB (assets/cards.db) from the flesh-and-blood-cards
# submodule's precomputed hashes (no image download — fast). See the DB constraint below.
git submodule update --init flesh-and-blood-cards   # one-time, if not cloned
python tool/build_card_db.py --out assets/cards.db
python tool/build_card_db.py --out /tmp/cards.db --limit 50   # quick test against 50 cards

# Price + manifest pipeline (see "Remote data updates" below). Stdlib + requests.
pip install requests
python tool/scrape_prices.py --from <card.json|raw-url> --out dist   # -> dist/prices.json
python tool/build_manifest.py --dir dist --base-url https://iamthermite.github.io/fabscan
```

First Android build is slow: `opencv_dart` downloads the OpenCV SDK (~100 MB) via CMake.

## Card data source (the `flesh-and-blood-cards` submodule)

`assets/cards.db` is built from the **`flesh-and-blood-cards`** git submodule — the
[IAmThermite fork](https://github.com/IAmThermite/flesh-and-blood-cards) tracked on its
**`feature/card-art-hashes`** branch (pinned in [.gitmodules](.gitmodules)). That branch ships
**precomputed** perceptual hashes for every printing in
`flesh-and-blood-cards/json/english/card.json`: each card carries `name`/`pitch`/`unique_id`
at the top level and a `printings[]` array, each printing carrying `phash_art` / `phash_full`
(stringified 63-bit ints), `image_url`, `set_id`, `foiling`, `edition` and `art_variations`.
[tool/build_card_db.py](tool/build_card_db.py) reads these straight into the DB — no image
download, no recompute. **The phashes are only usable because the fork's
`helper-scripts/calculate-phashes` pipeline is byte-for-byte equivalent to this app's Dart
`PHash`** (same 32×32 area-average downsample, 0.299/0.587/0.114 luma, top-left 8×8 DCT block
with the DC term excluded, and the regular art rect `0.10/0.16/0.80/0.42` ==
`ArtBbox.defaultRegular`). If that pipeline ever diverges, live captures stop matching — re-verify
before trusting a new branch/commit. The mainline (non-fork) branch has **no** phashes, so the
submodule must stay on `feature/card-art-hashes`.

## Scan pipeline (the core data flow)

`ScanController` ([lib/src/scan/scan_controller.dart](lib/src/scan/scan_controller.dart))
drives a live loop on the camera stream, processing one frame per `sampleEvery` (default 20)
guarded by a `_busy` flag — **all CV runs inline on the main isolate** (FFI `Mat`s don't
cross isolates trivially; moving it off-main is a known follow-up). Per frame:

1. `cameraImageToBgr` ([camera_utils.dart](lib/src/vision/camera_utils.dart)) — YUV420 → BGR `Mat`.
2. `CardDetector.detect` ([card_detector.dart](lib/src/vision/card_detector.dart)) — OpenCV contour detect + perspective deskew → upright `cardRgb` + a confidence `score`. When detection is below confidence it falls back to `captureGuideRegion`, cropping the fixed centered rectangle defined by `ScanConfig.captureRect` ([scan_config.dart](lib/src/vision/scan_config.dart)) — the **same** rect the on-screen alignment guide draws ([scan_screen.dart](lib/src/ui/scan_screen.dart)), so what the user lines up to is exactly what gets cropped/hashed. Below `minCaptureScore` (0.55) recognition is skipped.
3. `detection.computeHashes()` — art-crop hash + whole-card hash via `PHash`.
4. `OcrService.readTitle` ([ocr_service.dart](lib/src/vision/ocr_service.dart)) — Tesseract reads the title bar via hOCR, returning the text **and a word-level mean confidence** (0..100).
5. `CardRepository.recognize` ([card_repository.dart](lib/src/data/card_repository.dart)) → **title arm** or **phash arm** (see below) → load card + variants → save to `RecentsStore` (24h).

**Two recognition arms** (`CardRepository.recognize`):
- **Title arm (preferred when OCR is confident):** if `ocrConfidence >= minTitleConfidence` (default 60) and `CardDao.matchByTitle` fuzzy-matches the read title to a card name (normalized Levenshtein + containment, similarity ≥ `minTitleSimilarity` 0.72, in [title_matcher.dart](lib/src/data/title_matcher.dart)), the **name decides the card** and the phash picks the variant. When the same name maps to several cards (one per pitch — e.g. *Absorb in Aether* 1/2/3), `PitchDetector` ([pitch_detector.dart](lib/src/vision/pitch_detector.dart)) HSV-votes red/yellow/blue from the colour strip at the top of the deskewed card to filter to the right pitch before the phash variant pick. Pitch is used **only in the title arm** — it doesn't gate the phash arm, where pitch is already implicit in the hash, so a mis-sampled border can't reject a correct phash match. Falls back to canonical when there's no phash signal.
- **pHash arm (fallback):** `CardDao.matchByPhash` ([card_dao.dart](lib/src/db/card_dao.dart)) loads **all** print hashes into memory once (`_ensureCache`) and does a linear Hamming-distance scan per capture — the FAB set is only a few thousand rows. **Multi-arm**: compares `art` and `full` hashes and keeps the best arm under its threshold.

## Invariants you must not break

- **RGB everywhere into `PHash`.** `PHash.compute` ([phash.dart](lib/src/vision/phash.dart)) and the build tool both feed **RGB** pixels. Camera buffers are BGR — convert before hashing or matches silently fail.
- **The bundled DB's pHashes must stay pipeline-compatible.** `assets/cards.db` pHashes come from the `flesh-and-blood-cards` submodule (see the section above) via `python tool/build_card_db.py`. They only match live camera captures because the fork's hash pipeline mirrors this app's `PHash` — if you point the submodule at a different fork/branch, re-verify that equivalence first.
- **One art-crop tuning knob.** At scan time the app can't know a print's art type, so the app crops the art region with the fixed `ArtBbox.defaultRegular` ([fab_card.dart](lib/src/models/fab_card.dart) line 175) via the pure-Dart `ArtCrop.extract` ([art_crop.dart](lib/src/vision/art_crop.dart)), and the submodule's hash pipeline crops the identical `REGULAR_ART_BBOX = (0.10, 0.16, 0.80, 0.42)`. Change the app side and the stored hashes no longer match — you'd need the fork to recompute against the new rect.
- **Hamming thresholds** (in `CardDao`): `artThreshold = 15`, `fullThreshold = 8`. These mirror the reference scanner; lower = stricter.
- **Schema is duplicated** between [card_database.dart](lib/src/db/card_database.dart) (`schema`, the empty-DB fallback) and [tool/build_card_db.py](tool/build_card_db.py) (`_create_schema`). Keep them in sync.
- **`CardDatabase.bundledVersion`** (currently `'dev4'`) gates re-copying the asset over a previously installed DB. Bump it after shipping a new `cards.db` or the old one persists on-device.
- **Card-DB version alignment.** The remote-update flow compares the published `manifest.card_db.version` to the *installed* DB's `meta.version` (stamped by `build_card_db.py`). When you refresh `assets/cards.db`, keep `bundledVersion`, the bundled DB's `meta.version`, and the published version coherent — otherwise a fresh install will needlessly re-download an identical DB on first launch.
- **`prices.db` is separate and app-owned.** Pricing lives in its own writable DB ([price_store.dart](lib/src/db/price_store.dart)); never mix it into the read-only `cards.db`, which is replaced wholesale on a `bundledVersion` bump / remote swap.

## Android toolchain (pinned — do not bump blindly)

The Flutter 3.44 template scaffolds AGP 9 / Gradle 9 / Kotlin 2.3, which **breaks the build**
(Gradle 9 removed `jcenter()` that `flutter_tesseract_ocr` 0.4.30 needs; AGP 9 NPEs on the
Flutter plugin). Pinned instead: `com.android.application` **8.11.1** + Kotlin **2.1.0** in
[android/settings.gradle.kts](android/settings.gradle.kts), Gradle wrapper **8.13**, and
`minSdk = 24` (for opencv_dart) in [android/app/build.gradle.kts](android/app/build.gradle.kts).
AGP must stay **>= 8.9.1** (androidx.core 1.17 from compileSdk 36) and **< 9.0** (to keep
`jcenter()`). Re-check OCR-plugin AGP-9 support before raising these.

## iOS

iOS is supported but **must be built/run on a Mac** (Xcode + CocoaPods); it can't be
compiled from the Linux dev box. Deployment target is **iOS 13.0**
([ios/Runner.xcodeproj](ios/Runner.xcodeproj)). The `Podfile` is generated on the first
`flutter build ios` / `flutter run` on a Mac. All plugins support iOS (`camera_avfoundation`,
`opencv_dart`, `flutter_tesseract_ocr` via SwiftyTesseract, `sqflite_darwin`, `url_launcher_ios`).

Things that differ from Android and must not regress:

- **Camera frame layout.** iOS streams YUV420 as **2-plane biplanar** (Y + interleaved CbCr),
  Android as **3-plane** YUV_420_888. `cameraImageToBgr` / `_yuv420ToNv21`
  ([camera_utils.dart](lib/src/vision/camera_utils.dart)) branch on `planes.length` to repack
  both into NV21 — don't reintroduce a hard `planes[2]` read.
- **Camera permission.** `NSCameraUsageDescription` in [ios/Runner/Info.plist](ios/Runner/Info.plist)
  is mandatory; the app crashes on camera open without it. Audio is disabled
  (`enableAudio: false`) so no mic key is needed.
- **OCR tessdata (manual Xcode step).** `flutter_tesseract_ocr` on iOS loads `tessdata` from the
  **app-bundle root**, not Flutter assets — drag `assets/tessdata` into the Runner target in
  Xcode as a *folder reference*. Until that's done OCR silently no-ops (it's wrapped in try/catch
  and is only a disambiguation aid), so scanning still works.
- **Bundle id.** Like the Android `applicationId`, set a real bundle identifier (currently
  `com.example.fabscan`) before release.

## Pricing

Prices are **precomputed offline**, not fetched live on-device. The daily
[tool/scrape_prices.py](tool/scrape_prices.py) scrapes every print in `card.json` —
MinMaxGames (AUD) + Fluke & Box (NZD) by bulk-crawling each Shopify storefront's public
`/products.json`, TCGplayer (USD) per-print via the product id in `tcgplayer_url` +
TCGplayer's `mpapi` price-points endpoint, and Cardmarket (EUR) best-effort (usually
degrades to link-out) — into a single `prices.json` (+ daily FX rates).

In the app, [PriceStore](lib/src/db/price_store.dart) is a writable `prices.db` cache;
[PricingService](lib/src/pricing/pricing_service.dart) `.quotesFor(card, print)` joins
stored rows on `CardPrint.id` (== printing `unique_id`) and returns, per configured
`PriceSource`, either the stored price **converted to the user's display currency**
([currency.dart](lib/src/pricing/currency.dart), default NZD) or — always, as a fallback —
a link-out via `PriceSource.searchUrl` (TCGplayer deep-links via `print.tcgplayerUrl`). So
every source is at minimum tappable, even offline. The dataset's `generated_at` is shown in
the price panel. **Contract:** the per-source keys in `prices.json` must byte-match each
`PriceSource.name` (`MinMaxGames`, `Fluke & Box`, `TCGplayer`, `Cardmarket`) — a mismatch
silently downgrades that source to a link-out.

## Remote data updates

A small `manifest.json` (published to GitHub Pages, `https://iamthermite.github.io/fabscan/`)
drives launch-time updates of *both* data files; [RemoteUpdateService](lib/src/data/remote_update_service.dart)
fetches it once per launch, fire-and-forget (never blocks the camera; offline/error leaves
existing data intact):
- **prices** → downloaded into `prices.db` when stale (>24h since `fetched_at`) **and** the
  dataset's `generated_at` changed. Refresh-staleness keys on `fetched_at`; the user-facing
  freshness keys on `generated_at` — keep these distinct.
- **card_db** → whenever `manifest.card_db.version` differs from the installed DB's
  `meta.version`, the new `cards.db` is pulled and **hot-swapped** ([CardDatabase.replaceWith](lib/src/db/card_database.dart)
  + [CardRepository.replaceDao](lib/src/data/card_repository.dart)), so card data is never
  stale when a newer build exists — no app release needed.

Publishing: two GitHub Actions ([.github/workflows/](.github/workflows/)) — `scrape-prices.yml`
(daily) and `build-card-db.yml` (weekly / `workflow_dispatch`) — each check out the existing
`gh-pages` files, rebuild only their artifact, regenerate `manifest.json` via
[tool/build_manifest.py](tool/build_manifest.py) (so the untouched section is preserved), and
publish to `gh-pages` (served by Pages). They share a `concurrency` group to avoid push races.

## Wiring

[main.dart](lib/main.dart) opens the card DB + recents store + `PriceStore`, optionally seeds
`prices.db` from a bundled `assets/prices.json`, then injects `CardRepository`, `RecentsStore`,
`PricingService`, and `RemoteUpdateService` via `provider` ([app.dart](lib/app.dart)) and
kicks off `RemoteUpdateService.checkForUpdates()` in the background after `runApp`. The app
opens on `ScanScreen`. Set a real `applicationId` (currently `com.example.fabscan`) before release.
