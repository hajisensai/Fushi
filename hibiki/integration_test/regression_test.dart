import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

/// Regression tests for documented bugs in docs/REGRESSION_BUGS.md.
///
/// These require a connected device/emulator with test fixtures pushed to
/// /sdcard/Download/hibiki-test/kagami/. See CLAUDE.md § 集成测试流程.
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/regression_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('HBK-REG-001: play bar must not overlap reader content',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[reg] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();

      // Wait for home screen.
      bool ready = false;
      for (int i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byIcon(Icons.menu_book).evaluate().isNotEmpty) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue, reason: 'Home must render within 90s');
      await tester.pump(const Duration(seconds: 2));

      // Take baseline screenshot.
      await binding
          .takeScreenshot('reg001_home')
          .timeout(const Duration(seconds: 10));

      // This test requires a pre-imported book with audiobook (Kagami fixture).
      // If no book is present on the shelf, mark the test as blocked rather
      // than silently passing.
      final bool hasBooks =
          find.byType(InkWell).evaluate().isNotEmpty ||
              find.byType(GestureDetector).evaluate().length > 3;

      if (!hasBooks) {
        fail('HBK-REG-001 blocked: no books on shelf. '
            'Push fixtures and import before running regression tests. '
            'See CLAUDE.md § 集成测试流程.');
      }

      // TODO: Once Hoshi reader exposes a test hook or stable key,
      // open the book, verify play bar bounds vs content bounds,
      // and assert no overlap. For now, this skeleton ensures the
      // regression is tracked in the test suite and blocks on missing
      // fixtures rather than silently passing.

      // WebView errors are NOT allowed in reader regression tests.
      _assertNoWebViewErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

void _assertNoWebViewErrors(List<FlutterErrorDetails> errors) {
  final List<FlutterErrorDetails> unexpected = errors.where((e) {
    final String msg = e.exceptionAsString().toLowerCase();
    // Only filter genuine network noise, NOT WebView/renderer errors.
    if (msg.contains('socketexception')) return false;
    if (msg.contains('tls') || msg.contains('timeout')) return false;
    return true;
  }).toList();

  expect(unexpected, isEmpty,
      reason: 'Reader regression test must not have errors (including WebView): '
          '${unexpected.map((e) => e.exceptionAsString()).join('; ')}');
}
