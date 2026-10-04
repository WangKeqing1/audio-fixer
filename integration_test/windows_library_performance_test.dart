import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/large_library_scenario.dart';

// Run on Windows: flutter test integration_test/windows_library_performance_test.dart
//   -d windows --profile --reporter expanded
// This renders the real Windows Flutter engine. Media and playback events are
// synthetic; it does not benchmark disk scanning, codecs or physical window drag.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows 4096-track library interaction performance evidence', (
    tester,
  ) async {
    expect(Platform.isWindows, isTrue);
    final frames = <FrameTiming>[];
    void recordFrames(List<FrameTiming> values) => frames.addAll(values);
    binding.addTimingsCallback(recordFrames);
    addTearDown(() => binding.removeTimingsCallback(recordFrames));
    final interaction = await runLargeLibraryScenario(tester);
    // Engine frame timings are delivered in batches, independently of pumps.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(
      frames,
      isNotEmpty,
      reason: 'A native engine run must produce frame evidence',
    );
    Map<String, int> summary(Iterable<Duration> values) {
      final micros = values.map((value) => value.inMicroseconds).toList()
        ..sort();
      return {
        'p50_us': micros[(micros.length * .5).floor()],
        'p90_us': micros[(micros.length * .9).floor()],
        'max_us': micros.last,
      };
    }

    final result = {
      'runtime': 'Windows Flutter profile, synthetic media/playback',
      'scenario': interaction,
      'frame_count': frames.length,
      'build': summary(frames.map((frame) => frame.buildDuration)),
      'raster': summary(frames.map((frame) => frame.rasterDuration)),
      'total': summary(frames.map((frame) => frame.totalSpan)),
      'timing_policy':
          'Report distributions; no absolute host-dependent frame budget',
    };
    binding.reportData = result;
    final report = File(
      Platform.environment['AUDIO_FIXER_PERF_REPORT'] ??
          'build/ci/windows/library-performance.json',
    );
    await report.parent.create(recursive: true);
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
    );
    // ignore: avoid_print
    print('WINDOWS_LIBRARY_PERFORMANCE ${jsonEncode(result)}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
