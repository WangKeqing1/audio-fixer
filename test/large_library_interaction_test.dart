import 'package:flutter_test/flutter_test.dart';

import 'support/large_library_scenario.dart';

void main() {
  testWidgets('4096 songs with covers and tasks keep interaction state', (
    tester,
  ) async {
    await runLargeLibraryScenario(tester);
  });
}
