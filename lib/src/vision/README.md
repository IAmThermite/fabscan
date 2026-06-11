# Scan & detection pipeline

How FabScan turns a live camera frame into a recognised Flesh and Blood card.
Everything here runs **offline**, inline on the main isolate, against the
bundled SQLite database of precomputed perceptual hashes. It is a Dart port of
the `fab-tabletop` reference scanner (same edge strategies, art-crop ratios, DCT
pHash, and Hamming thresholds).

## At a glance

```
camera frame (YUV420)
  │
  ▼  cameraImageToBgr                          camera_utils.dart
BGR Mat
  │
  ▼  CardDetector.detect (Canny + deskew)      card_detector.dart
  │   └─ low confidence? captureGuideRegion (fixed centered crop)
upright card RGB  (420 × 588)
  │
  ├─▼  computeHashes  ─►  art-crop pHash + full-card pHash    phash.dart
  │
  └─▼  OcrService.readTitle (Tesseract → text + confidence)  ocr_service.dart
  │
  └─▼  PitchDetector.detect (HSV vote on top colour strip) pitch_detector.dart
  │
  ▼  CardRepository.recognize                                card_repository.dart
  │   ├─ title arm: OCR conf ≥ 60 & fuzzy name match  ─► card by name,   card_dao.dart
  │   │             pitch filters by colour, phash           title_matcher.dart
  │   │             picks the variant
  │   └─ phash arm: linear Hamming scan, art ≤15 / full ≤8   card_dao.dart
matched card + variants
  │
  ▼  stop stream, save to recents (24h), show result + prices
```

The whole loop is driven by `ScanController`
([scan_controller.dart](scan_controller.dart) lives in `../scan/`).

## Stage by stage

### 1. Camera setup — `ScanController.initialize`
Opens the back camera at `ResolutionPreset.high`, audio disabled,
`ImageFormatGroup.yuv420`. Records the sensor orientation (needed to rotate
frames upright in the fallback path) and attaches `_onFrame` to the image
stream.

### 2. Frame sampling — `ScanController._onFrame`
The stream fires continuously; we process only **one frame in `sampleEvery`**
(default 20) and only when not already `_busy`. CV work runs inline on the main
isolate — FFI `Mat`s don't cross isolates trivially, so moving detection
off-main is a known follow-up.

### 3. YUV420 → BGR — `cameraImageToBgr` ([camera_utils.dart](camera_utils.dart))
Repacks the camera buffer into NV21 and lets OpenCV (`cv.cvtColor`,
`COLOR_YUV2BGR_NV21`) produce a BGR `Mat`. It branches on `planes.length` to
handle both chroma layouts:

| Platform | Layout | Planes |
|----------|--------|--------|
| Android | YUV_420_888 | 3 (Y, separate U, separate V) |
| iOS | 420YpCbCr8BiPlanar | 2 (Y + interleaved CbCr) |

Row-stride padding is honoured on the Y and chroma planes. The caller owns and
disposes the returned `Mat`.

### 4. Card detection — `CardDetector.detect` ([card_detector.dart](card_detector.dart))
Grayscale the frame, then run up to four edge passes
`[blur, cannyLow, cannyHigh, dilations]`:

```
gaussianBlur → canny → dilate → findContours(RETR_LIST)
```

For each contour:
- reject if area is outside **5–60%** of the frame,
- fit a 4-point polygon with `approxPolyDP` over increasing epsilon (0.02→0.10),
- score the quad 0..1.

The **score** combines three geometric checks (hard-rejecting to 0 on failure):

| Factor | Weight | What it measures |
|--------|--------|------------------|
| Rectangularity | 0.5 | opposite sides similar (rejects trapezoids) + corner angles within 25° of 90° |
| Centering | 0.3 | quad centroid distance from frame centre |
| Aspect fit | 0.2 | closeness of long/short ratio to the target **1.4** (valid range 1.1–2.0) |

The best quad across all passes is kept; a score above **0.85** short-circuits
the remaining (slower) passes.

### 5. Deskew — `CardDetector._warp`
Orders the winning corners TL/TR/BR/BL, re-labels them if the card is lying
landscape (so the short edge maps to the top → upright portrait), then applies a
perspective transform onto the canonical **420 × 588** card and converts
BGR→RGB. The four source corners are also returned as `quad` for the live
overlay.

### 6. Fallback capture — `CardDetector.captureGuideRegion`
When no contour clears `minCaptureScore` (**0.55**) — e.g. a black-bordered card
on a dark mat where edges vanish — the detector rotates the frame upright using
the sensor orientation and crops the fixed centered rectangle defined in
[scan_config.dart](scan_config.dart): **72%** of the frame width at a **1 : 1.4**
aspect, clamped to frame height. This is the *same* rectangle the on-screen
alignment guide draws, so what the user lines up is exactly what gets hashed.
Marked `source: 'guide'` (vs `'contour'`); only contour quads are drawn as an
outline.

### 7. Perceptual hashing — `PHash.compute` ([phash.dart](phash.dart))
`detection.computeHashes()` produces **two** hashes per capture:

- **art** — the `ArtBbox.defaultRegular` region of the card
  (x 0.10, y 0.16, w 0.80, h 0.42; see [../models/fab_card.dart](../models/fab_card.dart)),
- **full** — the whole upright card.

Each hash:
1. area-average downsample the region to **32×32** grayscale
   (`0.299R + 0.587G + 0.114B`),
2. 2D DCT,
3. take the top-left **8×8** low-frequency block, **excluding** the DC term,
4. threshold each of the 63 coefficients against the median → 63 bits.

The result is a non-negative 64-bit int (DC bit always 0), stored as a SQLite
`INTEGER`.

> ⚠️ **RGB in, always.** Both `PHash.compute` and `ArtCrop.extract`
> ([art_crop.dart](art_crop.dart)) expect RGB. Camera buffers are BGR — they're
> converted in `_warp` / `captureGuideRegion` before hashing. The build tool
> feeds RGB too; if the two diverge, matches silently fail.

### 7b. Pitch detection — `PitchDetector.detect` ([pitch_detector.dart](pitch_detector.dart))
Samples the colour strip at the top of the upright card (Y 1–4%, X 25–75% by
default), HSV-converts each pixel, skips neutrals (`s < 0.20`) and shadow
(`v < 0.15`), and buckets the rest by hue: red (`h < 25 ∨ h > 340`), yellow
(`25–65`), blue (`190–260`). The winning bucket needs a **0.60** share of the
voting pixels — otherwise it returns null (non-pitch cards, mixed lighting, or
atypical art). Pure Dart on the same packed RGB the phash hashes.

### 8. Title OCR — `OcrService.readTitle` ([ocr_service.dart](ocr_service.dart))
Crops the title strip (y 1%, h 8%, 16% side inset), grayscales and 3×
nearest-neighbour upscales it, then runs Tesseract via `extractHocr` in
single-line mode (PSM 7) with a character whitelist. The hOCR output carries
per-word `x_wconf` values, which are averaged over letter-bearing words into a
**word-level mean confidence** (0..100) — page-level confidence is unreliable in
PSM 7. Wrapped in try/catch — if `tessdata` is missing or the native call fails
it silently no-ops (confidence 0), and recognition falls back to the phash arm.

### 9. Recognition — `CardRepository.recognize` ([../data/card_repository.dart](../data/card_repository.dart))
Recognition has **two arms**:

**Title arm (preferred when OCR is confident).** When the title is read with
confidence ≥ `minTitleConfidence` (**60**), `CardDao.matchByTitle`
([card_dao.dart](card_dao.dart)) fuzzy-matches it against the card names — a
normalized Levenshtein ratio with a containment boost
([../data/title_matcher.dart](../data/title_matcher.dart)), accepted above a
similarity of **0.72**. The matched **name decides the card**. One name can map
to several cards (one per pitch — e.g. *Absorb in Aether* 1/2/3); when a pitch
was detected, candidates are filtered to that pitch. If the filter eliminates
everything (mis-sample or a non-pitch card sharing the name) the unfiltered set
is kept rather than discarding a real match. The **phash then picks the
variant** among the remaining candidates' prints (thresholds ignored — the card
is already known). With no usable phash signal it falls back to the canonical
print. Arm reported as `title`.

**pHash arm (fallback).** Otherwise `CardDao.matchByPhash`:

1. loads **all** print hashes into memory once (`_ensureCache`) — the FAB set is
   only a few thousand rows, so a linear scan per capture is cheap;
2. for each print computes the Hamming distance on both arms and keeps the best
   one under its threshold:

   | Arm | Threshold | Compares |
   |-----|-----------|----------|
   | `art` | ≤ 15 | art-crop hash |
   | `full` | ≤ 8 | whole-card hash |

3. sorts candidates ascending by distance and returns the top 5;
4. loads the winner's card with **all its variant prints** (set/foil/art).

Returns `null` when neither arm produces a match. In debug builds,
`diagnoseClosest` logs the globally nearest prints *ignoring* thresholds, so
poor matches can be debugged from the console.

> The confidence gate (60) and similarity gate (0.72) together guard against
> misreads: a garbled title fuzzy-matches no name and quietly falls through to
> the phash arm. Both gates are tunable — `minTitleConfidence` on
> `CardRepository`, `minTitleSimilarity` on `CardDao`.

### 10. Finalize / resume — `ScanController._finalize` / `resume`
On a match: stop the image stream, record the card to `RecentsStore` (24h
window), flip state to `matched`; the UI shows the card, variant carousel, and
prices. `resume()` clears the result, resets counters, and restarts the stream.

## Invariants (don't break these)

- **RGB everywhere into `PHash`** — convert BGR camera buffers first.
- **The bundled `assets/cards.db` must be recomputed with this exact pipeline.**
  Hashes are crop- and code-sensitive; copying the reference project's
  precomputed hashes will *not* match live captures.
- **One art-crop knob** — `ArtBbox.defaultRegular`. The app can't know a print's
  art type at scan time, so app and build tool both crop this fixed region.
  Change it in one place, then **rebuild the DB**.
- **Thresholds** `artThreshold = 15`, `fullThreshold = 8` mirror the reference
  scanner; lower = stricter.

Rebuild the database after touching any crop/hash code:

```bash
dart run tool/build_card_db.dart            # full download + recompute
dart run tool/build_card_db.dart --limit 50 # quick smoke test
```

## Files

| File | Role |
|------|------|
| [../scan/scan_controller.dart](../scan/scan_controller.dart) | Orchestrates the loop: sampling, detect, hash, OCR, recognise, finalize |
| [camera_utils.dart](camera_utils.dart) | YUV420 (Android 3-plane / iOS biplanar) → BGR `Mat` |
| [card_detector.dart](card_detector.dart) | Canny contour detection, scoring, perspective deskew, guide-region fallback |
| [scan_config.dart](scan_config.dart) | Geometry of the centered capture rectangle (guide + fallback) |
| [phash.dart](phash.dart) | 32×32 DCT → 64-bit perceptual hash + Hamming distance |
| [art_crop.dart](art_crop.dart) | Pure-Dart RGB crop shared by app and build tool |
| [ocr_service.dart](ocr_service.dart) | Tesseract title-bar OCR → text + word-level mean confidence |
| [pitch_detector.dart](pitch_detector.dart) | HSV vote on the top colour strip → pitch 1 (red) / 2 (yellow) / 3 (blue) |
| [../data/card_repository.dart](../data/card_repository.dart) | Bridges vision pipeline and the DB; chooses the title vs phash arm; builds debug info |
| [../data/title_matcher.dart](../data/title_matcher.dart) | Pure-Dart title normalization + Levenshtein fuzzy matching |
| [../db/card_dao.dart](../db/card_dao.dart) | In-memory pHash cache + multi-arm Hamming matching; fuzzy `matchByTitle` |
