# PixMind Face Lab v3 — current-main build

Base: the exact `SmartStudio-main (6).zip` uploaded after downloading the merged GitHub `main`.

## What changed
- Face recognition is temporarily decoupled from `Index next 20`, `Refresh latest 20`, and `Index all`.
- `People -> Face Lab v3` can analyze the latest 20 photos or all photos directly from the gallery.
- The existing MobileFaceNet model is kept unchanged.
- Face preprocessing now prefers canonical eye/nose landmark alignment, with the previous crop/roll path as fallback.
- Tiny/background/weak detections are filtered out before identity clustering.
- Matching thresholds and cluster refinement are less over-conservative while retaining runner-up and same-photo protections.
- Face Lab reports detected and ignored faces for calibration.
- `People in Photo` now shows a face thumbnail instead of only a numeric avatar.
- Search-index face summaries are synchronized when Face Lab runs independently.

## Intentionally unchanged
- Smart Search UX (`All/OCR/Object/Person/Scene/Date/Color/Describe/Image`)
- FastAPI semantic text embedding and voice input
- image-to-image visual embedding/indexing
- YOLO, scene labeling, OCR engines and OCR models
- ObjectBox gallery analysis
- teammate indexing/image-analysis changes outside the face subsystem
- `pubspec.yaml`, `pubspec.lock`, Android/iOS configuration, and model assets

## Safe test
1. Run `flutter --no-version-check pub get`.
2. Run `flutter --no-version-check analyze`.
3. Build only if there are no analyzer errors.
4. In the app open `Albums -> People -> Face Lab v3`.
5. Start with `latest 20`, using several genuinely different photos of the same 2–3 people plus group/background-face examples.

This is an experimental face-recognition branch. Keep the previous merged `main` / APK as the stable rollback point until real-photo tests pass.
