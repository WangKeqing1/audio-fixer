# Large-library responsiveness regression

## Confirmed issue and fix

The 4,096-song workload reproduced a CPU-side catalog/UI problem. Every read of
`tracks` filtered and copied the whole snapshot; `trackById` did the same before
its linear lookup. `selectedTrackIds` repeated that work. `taskForTrack` copied
and scanned tasks. In addition, the hidden Tasks tab eagerly constructed all
512 task cards on every controller notification. Its per-card track checks
amplified the full-library scans, including during selection and window layout.

The fix caches immutable catalog views and first-match ID indexes by their
actual inputs: track list identity, task list identity, settings identity and
current permission. Snapshot replacement, artwork validation, settings edits,
permission loss and reloads invalidate the affected view. Selection is pruned
against the current index and previously returned sets remain immutable.
Task cards use a lazy sliver with keyed index lookup. The fixed bulk toolbar
and task selection remain outside the scrolling list.

The existing thumbnail cache and playback-listener isolation already worked in
this scenario. Neither was rewritten: no eager decode of all covers is added,
no task/file safety check is weakened, and no audio is modified by the fixture.
The library page itself needed no source change after the measured hot paths
were fixed.

## Measured before/after

2026-10-04, Linux x86-64, Flutter 3.47.2 / Dart 3.13.2, debug widget tests.
Baseline application sources are commit
`64c57465e2467401a958edd6d28fb257f53435b4`. Both runs use the same authored
4,096-track / 512-task fixture, 96×96 cover PNG, desktop starting viewport,
scroll distances, seven selection toggles, 24 playback updates and four
responsive viewport transitions. No private catalog was read or uploaded.

These are Stopwatch **elapsed test-workload timings**, not native Windows frame
or GPU measurements and not per-click production latency promises. Framework
pumping/layout and the harness are included. Single-host timings vary; operation
counts and state preservation are the regression gates, not absolute milliseconds.

| Workload | Baseline elapsed | Final elapsed | Exclusion checks before → after |
| --- | ---: | ---: | ---: |
| Initial populated app | 4,501,262 µs | 1,257,498 µs | 21,070,592 → 16,392 |
| Eight scroll jumps and return | 834,969 µs | 613,553 µs | 258,048 → 0 |
| Seven selection toggles | 27,455,521 µs | 1,120,475 µs | 147,641,600 → 61,496 |
| 24 playback position events | 432,335 µs | 421,492 µs | 0 → 0 |
| Four responsive viewport changes | 15,223,532 µs | 491,344 µs | 84,200,452 → 32,800 |
| 512 catalog lookup/selection iterations | 1,596,549 µs | 4,486 µs | 8,388,608 → 0 |

A prior fixed-code repeat measured selection at 1,263,889 µs and resize at
561,459 µs, consistent with the large reduction. That repeat's scroll measured
864,479 µs: do not infer a reliable scroll/rendering improvement from one run.

Startup loaded only 9 visible/pre-cached covers; scrolling loaded 35 additional
covers, 44 distinct tracks total. Playback events caused zero catalog lookups,
zero library notifications, zero new cover reads, and retained the same artwork
widget. The selected song/detail state and scroll controller offset survived
responsive transitions. Task-card virtualization reduced initial track lookups
from 4,608 to 938; tasks remain accessible and bulk controls stay reachable after
scrolling.

## Reproduce and validate

```sh
flutter test --no-pub --concurrency=1 --reporter expanded \
  test/large_library_interaction_test.dart \
  test/large_library_performance_test.dart \
  test/library_index_test.dart \
  test/tasks_virtualization_test.dart
```

The interaction test prints `LARGE_LIBRARY_PHASE` and
`LARGE_LIBRARY_INTERACTION` JSON; the catalog probe prints
`LARGE_LIBRARY_CATALOG`. To compare a previous revision, copy the same fixture
and test sources into an isolated checkout of that revision; do not revert a
shared working tree while other changes are in progress.

The targeted Linux run passed 150 existing/new tests covering exclusions,
permission changes, artwork validation, immutable stale snapshots, rereads,
controller resilience, batch/export safety, preview write locks, task journeys,
fixed bulk controls and responsive navigation. The four focused files passed
7 tests after the final performance source change. `flutter analyze --no-pub`
and `git diff --check` also passed. Full-bundle validation is separate.

## Native Windows evidence

The added CI step runs:

```powershell
flutter drive --profile --no-pub --driver=test_driver/windows_library_performance.dart --target=integration_test/windows_library_performance_test.dart -d windows
```

Flutter 3.47.2's `flutter test` command does not support `--profile`; the
supported profile runner is `flutter drive` with the official `integrationDriver`.
The driver propagates test failures and validates profile mode, complete scenario
metrics and frame evidence before writing the report on the host. The target
also asserts `kProfileMode`, so a silent debug fallback fails rather than being
reported as a profile measurement.

It runs the same UI workload on the Windows Flutter engine and records frame
count plus p50/p90/max build, raster and total timing distributions. CI retains
`build/ci/windows/library-performance.json` and `library-performance.txt`.
Assertions gate correctness, bounded work and nonempty native frame evidence;
there is no flaky absolute FPS or 16 ms threshold.

This native harness was added and statically analyzed on Linux; **it has not
been executed on Windows in this change's local verification**. Its playback
backend and media catalog are deliberately synthetic. Viewport transitions
exercise responsive layout, not physical OS-window dragging. Disk scanning,
real audio decoding, drivers, GPU-specific behavior and the user's actual
Windows library still require a Windows run. No native Windows speedup is
claimed from the Linux results above.
