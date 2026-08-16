#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0
check_file() {
  if [[ -f "$1" ]]; then
    echo "[OK] $1"
  else
    echo "[MISSING] $1"
    fail=1
  fi
}

check_file assets/tessdata/ara.traineddata
check_file assets/tessdata/Arabic.traineddata
check_file assets/models/mobilefacenet.tflite
check_file assets/models/yolo11n_int8.tflite
check_file lib/services/ai/ocr_service.dart
check_file lib/services/ai/face_service.dart

if grep -q '^version: 2.2.2+9$' pubspec.yaml; then
  echo '[OK] pubspec version 2.2.2+9'
else
  echo '[WARN] pubspec version is not 2.2.2+9'
fi

if find . -type f -size +90M -not -path './build/*' -not -path './.git/*' | grep -q .; then
  echo '[WARN] Files larger than 90 MB:'
  find . -type f -size +90M -not -path './build/*' -not -path './.git/*' -print
else
  echo '[OK] no source file > 90 MB'
fi

exit "$fail"
