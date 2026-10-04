import 'package:integration_test/integration_test_driver.dart';

import 'windows_performance_report.dart';

// Official integrationDriver propagates target test failure as exit(1), and
// exits(0) only after this callback completes. A missing/invalid profile report
// or failed artifact write therefore also fails the host driver and CI step.
Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 8),
  responseDataCallback: writeWindowsPerformanceReport,
);
