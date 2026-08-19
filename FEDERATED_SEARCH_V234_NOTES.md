# PixMind v2.3.4 — Federated Local Search stable candidate

Base: `PixMind-v2.3.3-face-lab-v3-current-main`, which already contains the validated Face Lab v3 changes on top of the merged current main.

## Goal
Make Smart Search use whichever local index already knows the answer instead of requiring every photo to have a `search_index` row.

## Search sources
- People / named persons: Face Lab SQLite (`person_groups` + `person_assets`) directly.
- Dominant color: lightweight ObjectBox gallery analysis directly.
- Objects / OCR / scenes / date: heavy SQLite AI-content index.
- Visual image search / Describe: unchanged visual embedding path.

## Combination rule
Sources are UNIONed when one clause can be answered by more than one source, then different clauses are INTERSECTED by `assetId`.

Examples:
- `Fouad`: Face Lab results work even if those photos never ran Index All.
- `red`: ObjectBox color results work even if those photos never ran Index All.
- `Fouad + red`: Face Lab ids intersect ObjectBox color ids.
- `Fouad + car`: Face Lab ids intersect YOLO-indexed car ids.
- OCR/Object/Scene still require the AI-content index because those signals do not exist in the lightweight index.

## Face pipeline
Unchanged from v2.3.3. `Index next 20`, `Refresh latest 20`, and `Index all` still do NOT run ML Kit face detection or MobileFaceNet. Face Lab remains separate for stability/performance.

## Models intentionally unchanged
- MobileFaceNet / face alignment and thresholds
- YOLO
- ML Kit scene labeling
- current ML Kit + Tesseract OCR
- EfficientNet visual embeddings
- FastAPI semantic protocol

No PaddleOCR / EdgeFace files or runtime code were added.

## Files changed from v2.3.3
- `lib/data/database/db_helper.dart`
- `lib/data/repositories/precise_search_repository.dart`
- `lib/features/search/search_screen.dart`
- `lib/features/search/search_vocabulary.dart`
- `lib/services/smart_search_bridge.dart`

## Minimum device test before treating as final
1. Run Face Lab on photos that have NOT been through AI Index, name a person, search that name in All and Person.
2. Pick a color on photos analyzed only by the lightweight gallery index; verify color-only results.
3. Type `red` / `أحمر` in All; verify lightweight color results appear.
4. Combine named person + picked color; verify intersection works without AI Index.
5. AI-index some photos and test Person + Object, e.g. named person + `car`.
6. Re-test OCR, Object, Scene, Image, Describe, and Voice for regressions.
7. Run `flutter --no-version-check analyze`, then build only if there are no analyzer errors.
