#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

# Ten-minute HTTP windows prevent a slow connection from being mistaken for a
# dead connection. Gradle's wrapper prints its own download percentage.
export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.internal.http.connectionTimeout=600000 -Dorg.gradle.internal.http.socketTimeout=600000"

retry_command() {
  local label="$1"
  local attempts="$2"
  shift 2
  local number=1
  until "$@"; do
    if (( number >= attempts )); then
      echo "$label failed after $attempts attempts."
      return 1
    fi
    echo "$label interrupted (attempt $number/$attempts). Retrying in 8 seconds…"
    number=$((number + 1))
    sleep 8
  done
}

chmod +x tool/bootstrap_android.sh
./tool/bootstrap_android.sh

# tflite_flutter still needs libtensorflowlite_jni.so while YOLO uses LiteRT 2.x.
# Fresh full-project builds install the compatible interpreter library once.
if [[ ! -f android/app/src/main/jniLibs/arm64-v8a/libtensorflowlite_jni.so ]]; then
  echo "Installing MobileFaceNet Android native runtime…"
  chmod +x install_mobilefacenet_android_libs.sh
  ./install_mobilefacenet_android_libs.sh
fi

echo "[1/3] Downloading Flutter packages. Verbose mode shows every active download…"
retry_command "flutter pub get" 5 flutter pub get --verbose

echo "[2/3] Building release APKs. Gradle shows download/build progress below…"
# Do not blindly retry compiler/dependency errors: they are deterministic and
# repeating them only wastes time. Slow downloads are already protected by the
# ten-minute Gradle timeouts above and pub-get retries.
flutter build apk --release --split-per-abi --no-pub --verbose

echo "[3/3] Preparing the arm64 APK used by almost all current Android phones…"
mkdir -p dist
cp \
  build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
  dist/PixMind-merged-v2.2.0-arm64-v8a.apk
sha256sum dist/PixMind-merged-v2.2.0-arm64-v8a.apk \
  > dist/PixMind-merged-v2.2.0-arm64-v8a.apk.sha256

echo
echo "Finished. Copy this file to the phone whenever you want:"
echo "  $project_dir/dist/PixMind-merged-v2.2.0-arm64-v8a.apk"
