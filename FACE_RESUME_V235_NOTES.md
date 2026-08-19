# PixMind v2.3.5 — Persistent Face Lab Resume

Base: v2.3.4 Federated Search stable candidate.

Changes:
- Face Lab no longer resets unnamed clusters on every run.
- `20 التالية` processes the next 20 photos that do not already have a complete current Face v3 scan.
- `إكمال كل الصور` skips completed photos and processes only the remaining library.
- Progress is persisted in SQLite (`face_scans`), so resume works after stopping Face Lab or closing/reopening the app.
- Already-completed photos are skipped before opening image bytes, so no ML Kit / alignment / MobileFaceNet cost is paid again.
- Old or partial face passes remain eligible for reprocessing automatically.
- YOLO, OCR, scene, federated search, visual embeddings, and Face v3 thresholds/model are unchanged.
