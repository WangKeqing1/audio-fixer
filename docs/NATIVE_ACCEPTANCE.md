# Audio repair, inventory and original-save Android acceptance (0.4.0)

The preview assertions below are prepared native test coverage. Version 0.4.0 additionally adds common-tag replacement, local covers and the all-audio TXT inventory tool. They have
not yet been executed on an emulator or physical device in this implementation
session. Host unit tests, Flutter checks and an APK build cannot establish native
playback success. Retain the exact commit/device/run result when this harness is
executed; earlier native results do not cover these new assertions.

## New repair and inventory validation

The common-tag replacements have offline, real-file MP3/FLAC/M4A roundtrip tests, including selected-field replacement intent, stale values/cover hashes, number-pair counterparts, unknown tags, extra pictures and source/audio integrity. These checks run through Flutter's test engine and FFmpeg-generated fixtures, not an installed Android app.

The inventory has Dart service/widget coverage for permission, cancellation, late-operation events, save retry, partial coverage/output warnings and operation-lock cleanup. `tool/native_tests/run_audio_inventory_text_test.sh` exercises the production compiled Kotlin TXT formatter on the JVM. Kotlin compilation and these tests do not establish MediaStore or Android document-picker runtime behavior. The new inventory has not been run on a device in this implementation session.

To run the formatter after compiling the release Kotlin classes, with a JDK and Android SDK configured:

```sh
bash tool/native_tests/run_audio_inventory_text_test.sh
```

## Synthetic-only runtime

Use a clean disposable emulator and the QA package identity. Do not run the host
driver against a phone containing personal music. The driver creates 36 indexed
files under `Music/AudioFixerSynthetic/`: the two original MP3 fixtures plus 34
authored PCM WAVs. These include exact 59.999/60.000/60.001-second boundaries,
parent/nested/prefix-sibling folders and enough short rows to scroll a long list.
All files use generated signals and an authored cover. It never calls an online source,
uploads audio or operates arbitrary MediaStore entries.

```sh
python3 tool/android_runtime_driver_test.py
python3 tool/android_runtime_ci.py --serial emulator-5554
```

The emulator, adb server and these commands must share the same process/network
environment. In isolated command sandboxes, launch and hold the emulator and run
the driver inside one long-lived shell; an adb server in a separate sandbox
cannot see that emulator. Use the normal accelerated CI boot path where available.
Software-only startup may be slow or unusable; do not alter `/dev/kvm` or host
security settings to work around a missing acceleration capability.

## What the native harness checks

- Real permission denial, retry/grant and MediaStore query/read through content URIs
- Unicode existing metadata and embedded cover; no mock native MethodChannels
- The 60-second synthetic MediaStore WAV plays through the row button without
  changing selected tracks or causing a full tag read. Native `getState` must
  independently report advancing position and the expected duration
- A pinned player and the selection toolbar remain available after long list
  scrolling. Visible player controls pause, keep position stable, seek around
  the middle of the WAV, resume, switch tracks and close/release
- Playback can be restarted after refresh and after a failed file. Opening a
  detail page or another tab releases playback. The host presses Android Home,
  verifies the actual launcher, resumes the QA Activity and checks that playback
  stays stopped; it does not inject a Flutter lifecycle event
- A production-imported, app-private copy of the synthetic WAV plays, and its
  SHA-256 matches the host fixture. Authored corrupt and missing app-private
  inputs produce native failure events plus a visible error instead of hanging
- Starting an original save while preview plays stops the native player before
  host consent handling, blocks further play while consent is pending, and
  never restarts playback after cancellation
- Initial rows show decoded, per-file embedded thumbnails before a full detail
  read; missing-artwork rows keep a placeholder. Fresh controller reload still
  loads the correct thumbnail without falsely marking tags inspected
- A no-match lyric query stays unclassified until the visible instrumental
  button is pressed. The local annotation survives store reload and MediaStore
  refresh, skips repeated lyric requests, and leaves actual lyrics/cover intact.
  Removing it permits lyrics to be queried and explicitly reviewed again
- Selection toolbar stays in the same on-screen rectangle after long scrolling,
  with hit-testable select-all/query controls and a cancelled query retaining selection
- Actual settings controls exclude strictly sub-60-second audio and parent-folder
  descendants while preserving the 60-second boundary and similarly named sibling
- Excluded selections are removed and do not reappear when rules are toggled off;
  all backing rows and 34 filter-fixture file hashes remain unchanged
- Fresh controller/store initialization and MediaStore rescan preserve filter rules
  and eligible rows. This is initialization coverage, not process-kill coverage
- New candidate values start unchecked and need explicit selection
- Optional export cancel/retry through the real Android document picker
- Source whole-file SHA-256 unchanged after export and original-write consent cancel
- Explicitly reviewed original saved alongside an unreviewed selected track;
  persisted batch reports one saved and one skipped, with no inferred success
- Updated original and optional copy both fully decode; encoded packets, decoded
  samples, existing metadata and cover match; selected lyrics have the exact value
- Unapproved track remains byte-identical; temporary read/tag copies are released
- A separate fresh-Activity test retains a third-hash current synthetic file and
  original backup during startup inspection and reauthorization; explicit restore
  must first preserve the current version and block unsafe cleanup
- The recovery test holds an actual decoder paused on a separate synthetic WAV,
  then exercises the production Dart write lock before startup inspection,
  retry and explicit restore. It asserts native stop/release and blocks new play
  inside the lock. This checks the lock over real recovery calls; controller unit
  tests separately check that production recovery actions acquire that lock
- Legacy private imported-file new writes are rejected; existing private recovery
  records remain readable and recoverable
- The real native MediaStore original-save method rejects a deliberately stale source SHA-256
  before opening a truncating writer, leaving source bytes and journal state intact

The seeded-journal test checks the real native recovery implementation but does
not claim to reproduce process death at an exact instruction. It uses app-private
synthetic audio to separate byte restoration from MediaStore grant lifetime.

## Remaining device/manual cases

Do not mark these passed merely because automated test files exist:

- Physical Android 10, Android 11+, old-version write permission behavior, and OEM
  MediaStore/document-provider differences
- Actual process kill/power loss during backup, target truncation/write and after
  verification but before task persistence; check restored or verified state and
  retained visible recovery records when restoration cannot finish
- Permission revoked between preparation and write, source externally edited while
  consent is open, full storage, unwritable provider and read-back mismatch
- Batch stop midway, restart handling, retry failures without touching success,
  alternate export-directory cancellation and document-provider cleanup failure
- Playback in the user's usual player, without uploading or committing music
- Speaker/headphone output, audio focus interruption by another app, headset
  disconnection, and physical-device codec/provider behavior. A progressing
  MediaPlayer state does not prove sound was audible

Unit/Flutter tests additionally cover unknown/nonpositive duration, separate storage
volumes, settings failures, stale indexed-vs-parsed duration, exclusion-aware retries,
and narrow screens with large text. Unit/Flutter tests cover many failure-state transitions, but those do not replace
real Android API behavior for permission and storage failures. A green APK build
is compilation evidence only. Record command, commit, device API/ABI, outcome and
scope for every native run; preserve explicit not-run/blocked/failed distinctions.

## Evidence boundaries

Raw local reports/audio remain ignored under `build/android_runtime/`. The CI
artifact tool allows only named synthetic screenshots and check JSON for one day;
never add APKs, audio, raw logs, credentials or broad directories to that allowlist.
Backups support interrupted/failed writes, not general undo after every successful
save. Unknown startup content is retained until an explicit decision; restoring
the original first preserves the current version. Distinct unexported versions
cannot be silently discarded when completing recovery. Do not clear app data or
uninstall while unresolved retained versions remain.

The preview report records native duration, progress, pause/seek positions,
failure codes, imported-copy hash and the explicit lifecycle/write-lock
assertions. Host validation rejects missing assertions or inconsistent values.
Synthetic screenshots illustrate the UI; they are never treated as proof that
audio played. Recovery reports explicitly distinguish the release barrier from
controller wiring and a seeded journal from a timed process crash.
