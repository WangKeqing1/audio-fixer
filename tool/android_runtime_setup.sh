#!/usr/bin/env bash
set -euo pipefail

: "${ANDROID_HOME:?Hosted runner must provide the Android SDK}"
: "${RUNNER_TEMP:?This setup is for a disposable hosted runner}"
original_sdk="$ANDROID_HOME"
sdk="$RUNNER_TEMP/audio-fixer-runtime-sdk"
sdkmanager="$original_sdk/cmdline-tools/latest/bin/sdkmanager"
test -x "$sdkmanager"
test -s "$original_sdk/licenses/android-sdk-license"
mkdir -p "$sdk/licenses"
cp "$original_sdk/licenses/android-sdk-license" "$sdk/licenses/"
for directory in cmdline-tools platform-tools; do
  test -d "$original_sdk/$directory"
  ln -s "$original_sdk/$directory" "$sdk/$directory"
done

# Only the approved main Android license is visible. Never run --licenses,
# accept an extra license, or let Gradle install packages automatically.
packages=('platforms;android-35' 'platforms;android-36' 'build-tools;36.0.0'
          'ndk;28.2.13676358' 'cmake;3.22.1' 'emulator'
          'system-images;android-35;default;x86_64')
missing=()
for package in "${packages[@]}"; do
  relative="${package//;/\/}"
  mkdir -p "$(dirname "$sdk/$relative")"
  if [[ -s "$original_sdk/$relative/package.xml" ]]; then
    ln -s "$original_sdk/$relative" "$sdk/$relative"
  else
    missing+=("$package")
  fi
done
if (( ${#missing[@]} )); then
  "$sdkmanager" --sdk_root="$sdk" --channel=0 "${missing[@]}" </dev/null
fi
for package in "${packages[@]}"; do
  relative="${package//;/\/}"
  if [[ ! -s "$sdk/$relative/package.xml" ]]; then
    echo "::error::Required Android package $package was not installed. No extra license was accepted."
    exit 1
  fi
done
SDK_VIEW="$sdk" python3 - <<'PY'
import os
from pathlib import Path
import xml.etree.ElementTree as ET
sdk = Path(os.environ['SDK_VIEW'])
assert {p.name for p in (sdk / 'licenses').iterdir()} == {'android-sdk-license'}
for directory in ('platforms/android-35', 'platforms/android-36', 'build-tools/36.0.0',
                  'ndk/28.2.13676358', 'cmake/3.22.1', 'emulator',
                  'system-images/android-35/default/x86_64'):
    package = sdk / directory / 'package.xml'
    for node in ET.parse(package).getroot().iter():
        if node.tag.rsplit('}', 1)[-1] == 'uses-license':
            assert node.get('ref') == 'android-sdk-license', (directory, node.attrib)
    print((sdk / directory / 'source.properties').read_text())
PY
for key in ANDROID_HOME ANDROID_SDK_ROOT; do
  printf '%s=%s\n' "$key" "$sdk" >> "$GITHUB_ENV"
done
printf 'ANDROID_AVD_HOME=%s\n' "$RUNNER_TEMP/audio-fixer-runtime-avd" >> "$GITHUB_ENV"
printf '%s\n' "$sdk/platform-tools" "$sdk/emulator" >> "$GITHUB_PATH"
