import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/windows_performance_report.dart';

Map<String, dynamic> _report() => {
  'build_mode': 'profile',
  'platform': 'windows',
  'frame_count': 12,
  'scenario': {
    'tracks': 4096,
    'tasks': 512,
    'phases': {
      for (final phase in [
        'startup',
        'thumbnail_scroll',
        'selection',
        'playback_24_updates',
        'resize_4_transitions',
      ])
        phase: {'elapsed_us': 1234},
    },
  },
  for (final metric in ['build', 'raster', 'total'])
    metric: {'p50_us': 200, 'p90_us': 500, 'max_us': 700},
};

void main() {
  test(
    'driver saves complete native profile JSON to the host artifact path',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'performance_driver_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final output = File('${directory.path}/nested/library-performance.json');
      final report = _report();
      await writeWindowsPerformanceReport(report, outputPath: output.path);
      expect(jsonDecode(await output.readAsString()), report);
    },
  );

  test('driver rejects null, debug and non-Windows evidence', () {
    expect(() => validateWindowsPerformanceReport(null), throwsStateError);
    expect(
      () =>
          validateWindowsPerformanceReport(_report()..['build_mode'] = 'debug'),
      throwsStateError,
    );
    expect(
      () => validateWindowsPerformanceReport(_report()..['platform'] = 'linux'),
      throwsStateError,
    );
  });

  test('driver rejects missing frames and partial workload/timing reports', () {
    expect(
      () => validateWindowsPerformanceReport(_report()..['frame_count'] = 0),
      throwsStateError,
    );
    final partial = _report();
    ((partial['scenario'] as Map)['phases'] as Map).remove('selection');
    expect(() => validateWindowsPerformanceReport(partial), throwsStateError);
    expect(
      () => validateWindowsPerformanceReport(_report()..remove('raster')),
      throwsStateError,
    );
    expect(
      () => validateWindowsPerformanceReport(
        _report()..['total'] = {'p50_us': 700, 'p90_us': 500, 'max_us': 200},
      ),
      throwsStateError,
    );
  });

  test('invalid report fails before creating a success artifact', () async {
    final directory = await Directory.systemTemp.createTemp(
      'performance_driver_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final output = File('${directory.path}/library-performance.json');
    await expectLater(
      writeWindowsPerformanceReport(null, outputPath: output.path),
      throwsStateError,
    );
    expect(await output.exists(), isFalse);
  });
}
