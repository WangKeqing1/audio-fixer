# Quality checks and QA APK

[`.github/workflows/quality.yml`](../.github/workflows/quality.yml) runs on pushes to
`dev/audio-fixer-quality` and on pull requests. One Ubuntu 24.04 job checks Dart
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
  --target-platform android-arm64 --no-pub
```

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

The workflow does not upload APKs or artifacts, create releases, install on a
device, or publish to a store. Build logs and a compact test/package/checksum
summary are available on the Actions run. APK delivery remains separate and
requires the requested delivery destination.

Only generated synthetic media is used. No private input, audio files, device
logs, credentials, keystores or broad build/cache directories are uploaded.
Runtime Android acceptance still needs separate verification.

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
