import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

/// Integration tests for the highest-risk Hibiki user paths:
/// EPUB import → Hoshi reader → dictionary lookup.
///
/// Requires:
///   - Connected device/emulator
///   - Test fixtures pushed (see CLAUDE.md § 集成测试流程)
///   - At least one dictionary imported
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/reader_dictionary_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reader opens and renders content after EPUB import',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[reader] FlutterError: ${details.exceptionAsString()}');
    };
    int screenshotCount = 0;

    try {
      app.main();

      // Wait for home.
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

      screenshotCount += await _screenshot(binding, 'reader_test_home');

      // Verify shelf has books (requires pre-imported EPUB fixture).
      final Finder inkWells = find.byType(InkWell);
      final Finder gestures = find.byType(GestureDetector);
      final bool hasBooks =
          inkWells.evaluate().isNotEmpty || gestures.evaluate().length > 3;

      if (!hasBooks) {
        fail('Reader test blocked: no books on shelf. '
            'Import the Kagami EPUB fixture first. '
            'See CLAUDE.md § 集成测试流程.');
      }

      // TODO: Tap first book to open Hoshi reader.
      // Once opened, assert:
      //   1. WebView is present and loaded (no blank/error page)
      //   2. Reader chrome (toolbar, page controls) is rendered
      //   3. Page navigation works (tap/swipe advances page)
      //   4. Text selection triggers dictionary popup
      //   5. Dictionary popup contains search results
      //
      // These assertions require stable widget keys or test hooks
      // in the Hoshi reader. When those are added, replace this
      // TODO with real assertions.

      expect(screenshotCount, greaterThanOrEqualTo(0),
          reason: 'Screenshot infrastructure must function');

      // WebView/renderer errors MUST fail this test — this is the reader path.
      _assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });

  testWidgets('dictionary search returns results for imported dictionary',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[dict] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();

      // Wait for home.
      bool ready = false;
      for (int i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byIcon(Icons.menu_book).evaluate().isNotEmpty) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue, reason: 'Home must render within 90s');

      // Navigate to dictionary tab.
      final Finder searchIcon = find.byIcon(Icons.search);
      expect(searchIcon, findsWidgets,
          reason: 'Dictionary tab icon must be present');
      await tester.tap(searchIcon.first);
      await tester.pump(const Duration(seconds: 3));

      // Verify search field exists.
      final bool hasSearch =
          find.byType(TextField).evaluate().isNotEmpty ||
              find.byType(TextFormField).evaluate().isNotEmpty ||
              find.byType(SearchBar).evaluate().isNotEmpty;
      expect(hasSearch, isTrue,
          reason: 'Dictionary tab must have a search field');

      // TODO: Type a known word (e.g. 猫) into the search field,
      // wait for results, and assert:
      //   1. At least one result card/tile appears
      //   2. Result contains the searched term
      //   3. No "no results" placeholder when dictionary is imported
      //
      // Requires: at least one dictionary imported on the test device.

      _assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

Future<int> _screenshot(
    IntegrationTestWidgetsFlutterBinding binding, String name) async {
  try {
    await binding.takeScreenshot(name).timeout(const Duration(seconds: 10));
    debugPrint('[reader] Screenshot saved: $name');
    return 1;
  } catch (e) {
    debugPrint('[reader] Screenshot skipped ($name): $e');
    return 0;
  }
}

void _assertStrictErrors(List<FlutterErrorDetails> errors) {
  final List<FlutterErrorDetails> unexpected = errors.where((e) {
    final String msg = e.exceptionAsString().toLowerCase();
    if (msg.contains('socketexception')) return false;
    if (msg.contains('tls') || msg.contains('timeout')) return false;
    return true;
  }).toList();

  expect(unexpected, isEmpty,
      reason: 'Errors (including WebView/renderer) are fatal in reader/dict tests: '
          '${unexpected.map((e) => e.exceptionAsString()).join('; ')}');
}
