import 'dart:convert';
import 'dart:io';

/// Validate device-side reportData before publishing the host-side artifact.
/// Never let an accidentally debug run or absent frame evidence look successful.
Future<void> writeWindowsPerformanceReport(
  Map<String, dynamic>? data, {
  String? outputPath,
}) async {
  validateWindowsPerformanceReport(data);
  final report = File(
    outputPath ??
        Platform.environment['AUDIO_FIXER_PERF_REPORT'] ??
        'build/ci/windows/library-performance.json',
  );
  await report.parent.create(recursive: true);
  await report.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
}

void validateWindowsPerformanceReport(Map<String, dynamic>? data) {
  if (data == null ||
      data['build_mode'] != 'profile' ||
      data['platform'] != 'windows') {
    throw StateError(
      'Expected a native Windows profile-mode performance report',
    );
  }
  final frames = data['frame_count'];
  if (frames is! int || frames <= 0) {
    throw StateError('Native performance report contains no frame evidence');
  }
  final scenario = data['scenario'];
  if (scenario is! Map ||
      scenario['tracks'] != 4096 ||
      scenario['tasks'] != 512) {
    throw StateError(
      'Native performance report did not run the complete catalog',
    );
  }
  final phases = scenario['phases'];
  for (final phase in const [
    'startup',
    'thumbnail_scroll',
    'selection',
    'playback_24_updates',
    'resize_4_transitions',
  ]) {
    final measurement = phases is Map ? phases[phase] : null;
    final elapsed = measurement is Map ? measurement['elapsed_us'] : null;
    if (elapsed is! int || elapsed < 0) {
      throw StateError('Native performance report is missing phase: $phase');
    }
  }
  for (final metric in const ['build', 'raster', 'total']) {
    final summary = data[metric];
    final p50 = summary is Map ? summary['p50_us'] : null;
    final p90 = summary is Map ? summary['p90_us'] : null;
    final maximum = summary is Map ? summary['max_us'] : null;
    if (p50 is! int ||
        p90 is! int ||
        maximum is! int ||
        p50 < 0 ||
        p90 < p50 ||
        maximum < p90) {
      throw StateError('Native performance report has invalid $metric timings');
    }
  }
}
