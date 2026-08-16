#!/usr/bin/env bash
set -euo pipefail
TMP="${TMPDIR:-/tmp}/pixmind_litert142"
URL="https://dl.google.com/dl/android/maven2/com/google/ai/edge/litert/litert/1.4.2/litert-1.4.2.aar"
rm -rf "$TMP"
mkdir -p "$TMP/extracted"
if command -v curl >/dev/null 2>&1; then
  curl -L --retry 4 --retry-delay 2 -o "$TMP/litert-1.4.2.aar" "$URL"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$TMP/litert-1.4.2.aar" "$URL"
else
  echo "Need curl or wget to fetch LiteRT Android JNI libraries." >&2
  exit 1
fi
unzip -q "$TMP/litert-1.4.2.aar" 'jni/*/libtensorflowlite_jni.so' -d "$TMP/extracted"
mkdir -p android/app/src/main/jniLibs
cp -r "$TMP/extracted/jni/"* android/app/src/main/jniLibs/
echo "Installed MobileFaceNet JNI libraries:"
find android/app/src/main/jniLibs -name 'libtensorflowlite_jni.so' -print
