# Quality checks and QA APK

[`.github/workflows/quality.yml`](../.github/workflows/quality.yml) runs on pushes to
`main` and `dev/audio-fixer-quality`, and on pull requests. One Ubuntu 24.04 job checks Dart
formatting, runs `flutter analyze`, runs every test under `test/` including the
FFmpeg-backed synthetic-media cases, and builds an optimized ARM64 QA APK. A newer run cancels
an older run for the same branch or pull request; the job has a 35-minute limit.

## Reproducing the checks

Use Flutter **3.47.2**, its bundled Dart SDK, a full **Java 21 JDK** (including
`javac` and `jmods`), Python 3, FFmpeg/ffprobe, and the committed `pubspec.lock`.
From the repository root on Linux:

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze --no-pub
env -u AUDIO_FIXER_REAL_INPUTS flutter test --no-pub --coverage --concurrency=2 --reporter expanded
ORG_GRADLE_PROJECT_audioFixerQa=true flutter build apk --release --split-per-abi \
  --target-platform android-arm64 --pub
git diff --exit-code -- pubspec.lock
```

The release build keeps Pub enabled so Flutter regenerates its Android plugin
registrant for release mode, excluding the dev-only `integration_test` plugin.
Using `--no-pub` after tests can leave a test registrant on the release classpath.
The initial restore enforces the lockfile and the build checks it stays unchanged.

The test suite generates its own small audio signals and cover image. CI unsets
`AUDIO_FIXER_REAL_INPUTS`, checks Python/FFmpeg/ffprobe before testing, and rejects
skipped tests or an absent synthetic-media suite. It does not call live metadata
sources or use anyone's music library.

Media test packages come from the official Ubuntu HTTPS archives using the
runner's existing Ubuntu signing key. This avoids a slow hosted Azure mirror
seen in CI. Network operations have 30-second timeouts and three retries; this
setup step has a 10-minute ceiling within the unchanged 35-minute job limit.
Signature verification stays enabled and no third-party package source is added.

## Android SDK and license boundary

CI uses Android platforms 35 and 36, Build Tools 36.0.0, NDK 28.2.13676358,
and CMake 3.22.1. JNI dependencies require platform 35 and this CMake version in
addition to the app's platform 36. An isolated SDK view reuses installed hosted
packages and copies only the runner's existing `android-sdk-license`. Missing
exact packages are installed from the stable official SDK channel with standard
input closed. Any additional license or missing package causes a failure and
needs review; no license-acceptance command or blanket consent is used.

Gradle's automatic SDK download is disabled in a temporary configuration, so it
cannot silently expand this package list. The approved main terms are
[Android SDK License Agreement](https://developer.android.com/studio/terms).

## Results and limits

The output is `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`. CI verifies
`com.audiofixer.audio_fixer.qa`, the **Audio Fixer QA** label, the pubspec version
with `-qa` suffix, the ARM64 split version code, and the single `arm64-v8a` ABI. It
also checks that the APK is **not debuggable**, verifies its signature and Android
Debug test signer, and records its SHA-256 and size.

`--release` enables AOT optimization and shrinking. The repository still uses
**debug TEST signing, not production signing**. This is a side-by-side QA build
for ARM64 devices, not a production release. It can coexist with the normal app;
without the opt-in property, the normal package identity remains unchanged.

The workflow retains an exact allowlist consisting of the verified ARM64 QA APK,
its identity/provenance JSON, SHA-256, signature report and package badging for
**one day** as an Actions artifact. This permits delivery even if a development
workspace disappears. It does not create a release or publish to a store. No
music, private inputs, signing keys, credentials, broad logs or build directories
are included. The final APK can be delivered separately through the requested
file destination after exact-head checks pass.

The CI debug TEST signing key is ephemeral and may differ between runs or from
previous local QA builds. Compare the certificate before claiming update
compatibility. A different signature cannot replace an installed package with
the same ID; do not uninstall an older app without preserving its private data.
This pipeline does not generate or distribute a production signing identity.

Only generated synthetic media is used. No private input, audio files, device
logs, credentials, keystores or broad build/cache directories are uploaded.
Runtime Android acceptance still needs separate verification.

## Real Android runtime workflow

[`android-runtime.yml`](../.github/workflows/android-runtime.yml) separately runs
an AOSP API 35 x86_64 emulator when the hosted runner already permits access to
KVM. The workflow verifies KVM API access before starting the emulator. A preflight
failure means emulator and app tests did not run, not that application behavior
passed or failed. The separately approved hosted-runner setup may temporarily
give only the current test user read/write access to `/dev/kvm`, with original
owner/group/mode restored after emulator cleanup. That narrowly scoped setup is
for ephemeral GitHub-hosted runners; it does not authorize permission changes on
a developer computer or this cloud workspace. No world-writable mode or persistent
udev rule is required.

The native integration test uses the production widgets, controller, MediaStore
bridge, tag exporter and system document picker. Only the online metadata source
is replaced with explicitly synthetic, offline lyrics. The host generates and
indexes a covered MP3, then operates freshly observed Android permission and
save dialogs. Assertions cover permission denial/retry, content-URI reading,
Unicode tags, initially unchecked candidates, explicit field review, optional
export cancellation/retry, original-write consent cancellation/retry, an approved
song saved in a batch alongside an unapproved skipped song, persisted per-song
results/batch counters and temporary-copy cleanup. The host verifies the source
hash at cancellation checkpoints and the unapproved song's final exact hash.
Both the optional exported file and the updated original undergo independent
FFmpeg decoded-sample and encoded-packet checks and existing tag/cover checks.

A second native integration test launches a fresh Activity after the host seeds
an interrupted production-format journal, valid original backup and a distinct
current synthetic file. Startup inspection and reauthorization must leave the
third-hash current version untouched. Only explicit restoration may restore the
original; the current version must first be retained, and safe completion must
not discard an unexported distinct version. Private content-addressed legacy
copies remain readable for recovery, but new original-save requests are rejected.
The main MediaStore test separately rejects a deliberately stale source SHA-256
before writing, while retaining unchanged source bytes and a clear journal.

This is deterministic persisted-state recovery coverage, not a timed crash or
MediaStore grant-loss test. No production fault-injection hook is added. Check
the actual run result before treating any individual recovery assertion as passed.

The native harness resets its debug plugin registrant using `flutter pub get
--offline --enforce-lockfile`; dependencies must already have been restored by the
setup step. Both native test commands use `--no-uninstall`, so Flutter teardown
cannot delete the app-private evidence before host checks and the next test.
The harness never downloads packages or queries metadata providers.
Run `python3 tool/android_runtime_driver_test.py` for offline tests of the dialog
recognition/coordinate guard logic. Those tests are not Android runtime evidence.

A subsequent smoke builds and launches the optimized normal `lib/main.dart`
entrypoint on the emulator. It checks the resumed activity and launch errors;
settings navigation is attempted only when a unique accessible control can be
observed. It never presses an online query or connection-test button.

This workflow may retain an exact allowlist of synthetic screenshots and check
JSON for **one day**, with a SHA-256 manifest. It never uploads music, APKs, raw
logcat, compiler output, credentials or whole build directories. Artifacts are
evidence to inspect, not proof of visual quality by themselves. Successful
emulator results do not constitute physical-device or every-OEM acceptance.

Actions are pinned to verified commit IDs; checkout does not persist credentials,
permissions are `contents: read`, and no repository secrets or persistent caches
are configured. Flutter and Dart dependencies are fixed, while the hosted image,
Java 21 patch release and Ubuntu FFmpeg packages receive updates. Their actual
versions are recorded so this is a repeatable quality check, not a promise of
byte-identical APKs. Review action pins and toolchain changes together.

References: [checkout](https://github.com/actions/checkout/tree/v6.0.2),
[setup-java](https://github.com/actions/setup-java/tree/v5.2.0),
[flutter-action](https://github.com/subosito/flutter-action/tree/v2.21.0),
[Ubuntu runner inventory](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md),
[disabling SDK auto-download](https://developer.android.com/studio/intro/update#download-with-gradle).

## 0.3 original-save acceptance checklist

See [native acceptance scope](NATIVE_ACCEPTANCE.md) for commands, fixture boundaries
and the distinction between automated coverage and device behavior that still
needs runtime verification. Version changes or passing Dart tests do not by
themselves establish that Android write consent, recovery, or storage-provider
compatibility has passed.
