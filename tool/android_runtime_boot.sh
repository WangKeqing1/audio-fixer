#!/usr/bin/env bash
set -euo pipefail
: "${ANDROID_HOME:?}"
: "${ANDROID_AVD_HOME:?}"
mkdir -p "$ANDROID_AVD_HOME" build/android_runtime
"$ANDROID_HOME/emulator/emulator" -accel-check
# "no" answers only the hardware-profile customization question. SDK package
# setup is already complete and has no open stdin for accepting licenses.
printf 'no\n' | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd \
  --name audio_fixer_runtime --package 'system-images;android-35;default;x86_64' \
  --device pixel_2
nohup "$ANDROID_HOME/emulator/emulator" -avd audio_fixer_runtime -port 5554 \
  -no-window -no-audio -no-boot-anim -no-snapshot -wipe-data \
  -gpu swiftshader_indirect -accel on -cores 2 -memory 2048 \
  > build/android_runtime/emulator-local.log 2>&1 </dev/null &
printf '%s\n' "$!" > build/android_runtime/emulator.pid
timeout 60s adb -s emulator-5554 wait-for-device
booted=false
for (( attempt=0; attempt<120; attempt++ )); do
  if [[ "$(adb -s emulator-5554 shell getprop sys.boot_completed | tr -d '\r')" == 1 ]]; then
    booted=true
    break
  fi
  if ! kill -0 "$(cat build/android_runtime/emulator.pid)" 2>/dev/null; then
    echo '::error::Android emulator exited before boot; inspect the job log.'
    tail -80 build/android_runtime/emulator-local.log
    exit 1
  fi
  sleep 2
done
if [[ "$booted" != true ]]; then
  echo '::error::Accelerated AOSP emulator did not boot within four minutes; no app test was run.'
  tail -80 build/android_runtime/emulator-local.log
  exit 1
fi
adb -s emulator-5554 shell input keyevent KEYCODE_WAKEUP
adb -s emulator-5554 shell wm dismiss-keyguard
adb -s emulator-5554 shell getprop ro.build.version.release
adb -s emulator-5554 shell getprop ro.product.cpu.abi
