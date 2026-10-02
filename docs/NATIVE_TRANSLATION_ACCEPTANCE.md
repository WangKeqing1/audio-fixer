# Native offline translation acceptance

This is separate from the synthetic original-save/filter harness. The normal
save/filter harness still does not download translation models or call providers.
The translation workflow is narrowly triggered by relevant pull-request changes
or an explicit dispatch. Its model-download stage is an intentional acceptance
operation on one freshly booted disposable AOSP API 35 x86_64 emulator.

## What runs

1. Build the standalone `tool/native_translation_probe.dart` entrypoint as a
   non-debuggable release-AOT QA APK with its usual INTERNET declaration
2. Check bundled language identification on authored English/French sentences,
   explicit missing-model errors, and original-LRC preservation when translation
   is unavailable; translation itself must not implicitly download models
3. Explicitly download official ML Kit Chinese and French models (English is
   built in), then perform actual native translation
4. Rebuild the same probe with its test-only manifest overlay removing INTERNET;
   compare the package ID and signing-certificate SHA-256 before `adb install -r`
5. Verify the installed package's requested/granted INTERNET permission is absent
   and its app-private original-text sentinel survived the update; never uninstall
   or clear app data between the phases
6. Translate different, fresh authored English/French lines through the native
   bridge and actual Dart translation service, so a prior response cache cannot
   explain success; require nonempty changed Chinese results with matching line
   count and preserved LRC timestamps, multiple stamps and offset

Both merged APKs must omit `MlKitInitProvider`; explicit SDK channel use initializes
ML Kit on demand. This check does not prove that the SDK makes no telemetry
requests while the online download phase has network permission.

No VM-service connection is needed: the standalone AOT probe emits bounded
512-character Base64 frames of its synthetic JSON result to logcat. Each frame
has a phase, index/count and SHA-256 identity. The host reads only that marker
for the exact app PID, tolerates incomplete polling, and accepts only a complete,
checksum-verified result; conflicting or oversized frames fail. It does not save or upload raw device logs. This is why the offline phase
uses the standalone probe instead of `flutter test`, whose driver needs sockets.

## Commands and boundaries

```sh
python3 tool/android_translation_runtime_test.py
python3 tool/android_translation_runtime.py --allow-model-download
```

The second command requires the same approved SDK/KVM disposable environment as
`android-runtime.yml`. It intentionally downloads language models from Google.
Never run it on a personal device or uninstall an existing user installation.
No Wi-Fi, mobile-data, airplane-mode, firewall, or host network settings change.

Only the explicit QA/probe flags can select the offline overlay. The production
manifest keeps its existing INTERNET permission. Probe APKs are not deliverables.
The host verifies same-signature update compatibility within this one CI job;
it makes no claim that the ephemeral signer can update an older user's QA build.

The one-day evidence allowlist contains `download.json`, `offline.json`,
`summary.json`, and a SHA-256 manifest. APKs, models, audio, full logs, credentials,
and broad build/cache directories are excluded. Test-only flags and a green build
are not evidence of successful offline inference: inspect the actual run result.

## Remaining coverage

This exercises API 35 x86_64 and two supported source languages. It does not prove
all languages/OEMs, physical-device performance, production Play-services variants,
translation accuracy for arbitrary songs, download reliability on all networks,
or user-facing consent/cancel behavior. Those have separate unit/widget/manual
coverage. Original audio writes and recovery remain in the existing native flow.
