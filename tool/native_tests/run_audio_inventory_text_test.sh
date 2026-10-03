#!/usr/bin/env bash
# Compile :app:compileReleaseKotlin first; no Android device or new dependency required.
set -euo pipefail
inventory_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
inventory_classes="${1:-$inventory_root/build/app/tmp/kotlin-classes/release}"
inventory_stdlib="${KOTLIN_STDLIB_JAR:-}"
if [[ -z "$inventory_stdlib" ]]; then
  inventory_cache="${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib"
  inventory_stdlib="$(rg --files "$inventory_cache" | rg '/kotlin-stdlib-[0-9.]+\.jar$' | sort -V | tail -n 1)"
fi
if [[ ! -f "$inventory_classes/com/audiofixer/audio_fixer/AudioInventoryText.class" || ! -f "$inventory_stdlib" ]]; then
  echo 'Compile the release Kotlin classes and set KOTLIN_STDLIB_JAR to the cached Kotlin standard library.' >&2
  exit 1
fi
inventory_output="$(mktemp -d)"
trap 'rm -rf "$inventory_output"' EXIT
javac -encoding UTF-8 -cp "$inventory_classes:$inventory_stdlib" -d "$inventory_output" "$inventory_root/tool/native_tests/AudioInventoryTextTest.java"
java -cp "$inventory_output:$inventory_classes:$inventory_stdlib" com.audiofixer.audio_fixer.AudioInventoryTextTest
