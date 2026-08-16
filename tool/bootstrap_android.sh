#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

if [[ ! -f android/gradlew || ! -f android/gradle/wrapper/gradle-wrapper.jar ]]; then
  scaffold_dir="$(mktemp -d /tmp/pixmind-flutter-scaffold.XXXXXX)"
  flutter create \
    --platforms=android \
    --project-name=pixmind \
    --org=com.pixmind \
    "$scaffold_dir/scaffold"

  cp "$scaffold_dir/scaffold/android/gradlew" android/gradlew
  cp "$scaffold_dir/scaffold/android/gradlew.bat" android/gradlew.bat
  cp \
    "$scaffold_dir/scaffold/android/gradle/wrapper/gradle-wrapper.jar" \
    android/gradle/wrapper/gradle-wrapper.jar
  chmod +x android/gradlew

  echo "Generated the missing Gradle wrapper from your installed Flutter SDK."
fi

echo
echo "Gradle wrapper is ready. No phone was used and no app was installed."
