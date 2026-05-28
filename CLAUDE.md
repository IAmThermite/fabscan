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

# Rebuild the bundled card DB (assets/cards.db). Default mode downloads ~9k card
# images and recomputes hashes — slow, one-time. See the DB constraint below.
dart run tool/build_card_db.dart
dart run tool/build_card_db.dart --limit 50     # quick test against 50 cards
```

First Android build is slow: `opencv_dart` downloads the OpenCV SDK (~100 MB) via CMake.

## Scan pipeline (the core data flow)

`ScanController` ([lib/src/scan/scan_controller.dart](lib/src/scan/scan_controller.dart))
drives a live loop on the camera stream, processing one frame per `sampleEvery` (default 20)
guarded by a `_busy` flag — **all CV runs inline on the main isolate** (FFI `Mat`s don't
cross isolates trivially; moving it off-main is a known follow-up). Per frame:

1. `cameraImageToBgr` ([camera_utils.dart](lib/src/vision/camera_utils.dart)) — YUV420 → BGR `Mat`.
2. `CardDetector.detect` ([card_detector.dart](lib/src/vision/card_detector.dart)) — OpenCV contour detect + perspective deskew → upright `cardRgb` + a confidence `score`. Below `minCaptureScore` (0.55) recognition is skipped.
3. `detection.computeHashes()` — art-crop hash + whole-card hash via `PHash`.
4. `OcrService.readTitle` ([ocr_service.dart](lib/src/vision/ocr_service.dart)) — Tesseract reads the title bar via hOCR, returning the text **and a word-level mean confidence** (0..100).
5. `CardRepository.recognize` ([card_repository.dart](lib/src/data/card_repository.dart)) → **title arm** or **phash arm** (see below) → load card + variants → save to `RecentsStore` (24h).

**Two recognition arms** (`CardRepository.recognize`):
- **Title arm (preferred when OCR is confident):** if `ocrConfidence >= minTitleConfidence` (default 60) and `CardDao.matchByTitle` fuzzy-matches the read title to a card name (normalized Levenshtein + containment, similarity ≥ `minTitleSimilarity` 0.72, in [title_matcher.dart](lib/src/data/title_matcher.dart)), the **name decides the card** and the phash only picks the variant among that name's prints (a name maps to one card per pitch). Falls back to the canonical print when there's no phash signal.
- **pHash arm (fallback):** `CardDao.matchByPhash` ([card_dao.dart](lib/src/db/card_dao.dart)) loads **all** print hashes into memory once (`_ensureCache`) and does a linear Hamming-distance scan per capture — the FAB set is only a few thousand rows. **Multi-arm**: compares `art` and `full` hashes and keeps the best arm under its threshold.

## Invariants you must not break

- **RGB everywhere into `PHash`.** `PHash.compute` ([phash.dart](lib/src/vision/phash.dart)) and the build tool both feed **RGB** pixels. Camera buffers are BGR — convert before hashing or matches silently fail.
- **The bundled DB must be recomputed with this Dart pipeline.** `assets/cards.db` pHashes must come from `dart run tool/build_card_db.dart` (default download-and-recompute mode). `--reuse-phash` copies the reference project's precomputed hashes, which will **not** match live camera captures — use it only to populate names/images/variants while developing the UI.
- **One art-crop tuning knob.** At scan time the app can't know a print's art type, so both the app and the build tool crop the art region with the fixed `ArtBbox.defaultRegular` ([fab_card.dart](lib/src/models/fab_card.dart) line 175). Change it in one place and you must rebuild the DB.
- **Hamming thresholds** (in `CardDao`): `artThreshold = 15`, `fullThreshold = 8`. These mirror the reference scanner; lower = stricter.
- **Schema is duplicated** between [card_database.dart](lib/src/db/card_database.dart) (`schema`, the empty-DB fallback) and [tool/build_card_db.dart](tool/build_card_db.dart) (`_createSchema`). Keep them in sync.
- **`CardDatabase.bundledVersion`** (currently `'dev2'`) gates re-copying the asset over a previously installed DB. Bump it after shipping a new `cards.db` or the old one persists on-device.

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

Pluggable via `PriceSource` ([lib/src/pricing/](lib/src/pricing/)), registered in
`PricingService`. MinMaxGames (AUD) and Fluke & Box (NZD) fetch live from Shopify's public
`/search/suggest.json` (no API key, via `ShopifySource`); TCGplayer and Cardmarket have no
open price API so they deep-link out. User locale is NZ.

## Wiring

[main.dart](lib/main.dart) opens the DB + recents store and injects `CardRepository`,
`RecentsStore`, and `PricingService` via `provider` ([app.dart](lib/app.dart)). The app
opens on `ScanScreen`. Set a real `applicationId` (currently `com.example.fabscan`) before release.
