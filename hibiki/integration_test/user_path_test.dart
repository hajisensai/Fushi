import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

import 'helpers/focus_driver.dart';
import 'test_helpers.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full user path: tabs, settings, rapid switching',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[test] FlutterError: ${details.exceptionAsString()}');
    };
    int screenshotCount = 0;

    try {
      app.main();
      await _waitForHomeReady(tester);

      screenshotCount += await _takeScreenshotSafe(binding, 'home_books_tab');

      final FocusDriver driver = FocusDriver(tester);
      final List<Finder> navIcons = findPrimaryNavigationTargets();
      final int tabCount = navIcons.length;
      debugPrint('[test] Found $tabCount navigation icons');
      expect(tabCount, greaterThanOrEqualTo(2),
          reason: 'App should have at least 2 navigation icons');

      // --- Tab 1: Dictionary ---
      expect(await driver.focusWidget(navIcons[1]), isTrue,
          reason: 'Dictionary tab must be reachable by focus');
      await driver.activate();
      await tester.pump(const Duration(seconds: 3));

      expect(find.byType(Scaffold), findsWidgets,
          reason: 'Dictionary tab should render');
      screenshotCount += await _takeScreenshotSafe(binding, 'tab_dictionary');

      final bool hasSearch = find.byType(TextField).evaluate().isNotEmpty ||
          find.byType(TextFormField).evaluate().isNotEmpty ||
          find.byType(SearchBar).evaluate().isNotEmpty;
      expect(hasSearch, isTrue,
          reason: 'Dictionary tab must contain a search field');

      // --- Tab 2: Settings ---
      if (tabCount >= 3) {
        expect(await driver.focusWidget(navIcons[2]), isTrue,
            reason: 'Settings tab must be reachable by focus');
        await driver.activate();
        await tester.pump(const Duration(seconds: 3));

        expect(find.byType(Scaffold), findsWidgets,
            reason: 'Settings tab should render');
        screenshotCount += await _takeScreenshotSafe(binding, 'tab_settings');

        final bool hasListTiles = find.byType(ListTile).evaluate().isNotEmpty;
        expect(hasListTiles, isTrue,
            reason: 'Settings tab must contain ListTile entries');

        final Finder scrollable = find.byType(Scrollable);
        if (scrollable.evaluate().isNotEmpty) {
          await tester.drag(scrollable.first, const Offset(0, -300));
          await tester.pump(const Duration(seconds: 1));
          screenshotCount +=
              await _takeScreenshotSafe(binding, 'tab_settings_scrolled');
        }
      }

      // --- Return to first tab ---
      expect(await driver.focusWidget(navIcons[0]), isTrue,
          reason: 'Books tab must be reachable by focus');
      await driver.activate();
      await tester.pump(const Duration(seconds: 3));

      expect(find.byType(Scaffold), findsWidgets,
          reason: 'Books tab should render after round-trip navigation');
      screenshotCount +=
          await _takeScreenshotSafe(binding, 'home_books_return');

      // --- Rapid tab switching stability ---
      debugPrint('[test] Starting rapid tab switching (20 cycles)');
      int skippedTaps = 0;
      for (int i = 0; i < 20; i++) {
        final int tabIndex = i % navIcons.length;
        final Finder target = navIcons[tabIndex];
        if (target.evaluate().isEmpty) {
          skippedTaps++;
          continue;
        }
        // Focus-driven switch: a tab unreachable by focus counts as a skip,
        // preserving the original skip-budget assertion below.
        if (await driver.focusWidget(target)) {
          await driver.activate();
        } else {
          skippedTaps++;
        }
        await tester.pump(const Duration(milliseconds: 200));
      }

      await tester.pump(const Duration(seconds: 2));

      expect(skippedTaps, lessThan(5),
          reason: 'Most tab switches should find their target');
      expect(find.byType(Scaffold), findsWidgets,
          reason: 'App should survive rapid tab switching');

      // After rapid switching, verify the app is still interactive:
      // focus the first tab and verify it has content.
      expect(await driver.focusWidget(navIcons[0]), isTrue,
          reason: 'Books tab must be reachable by focus after rapid switching');
      await driver.activate();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byIcon(Icons.menu_book), findsWidgets,
          reason: 'Books tab icon must be present after rapid switching');

      if (screenshotsAreRequired) {
        expect(screenshotCount, greaterThan(0),
            reason: 'At least one screenshot must succeed for evidence');
      }
      debugPrint('[test] $screenshotCount screenshots captured');

      _assertNoUnexpectedErrors(errors, allowWebViewErrors: true);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<void> _waitForHomeReady(WidgetTester tester) async {
  for (int i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (isHomeReady()) {
      debugPrint('[test] Home ready at iteration $i (${i * 500}ms)');
      await tester.pump(const Duration(seconds: 1));
      return;
    }
    if (i > 0 && i % 20 == 0) {
      final bool hasScaffold = find.byType(Scaffold).evaluate().isNotEmpty;
      debugPrint(
          '[test] Still waiting for home... iteration $i, scaffold=$hasScaffold');
    }
  }
  debugPrint('[test] Home not ready after 90s');
  fail('Home page did not show navigation icons within 90s');
}

Future<int> _takeScreenshotSafe(
    IntegrationTestWidgetsFlutterBinding binding, String name) async {
  try {
    await binding.takeScreenshot(name).timeout(const Duration(seconds: 10));
    debugPrint('[test] Screenshot saved: $name');
    return 1;
  } catch (e) {
    debugPrint('[test] Screenshot skipped ($name): $e');
    return 0;
  }
}

void _assertNoUnexpectedErrors(List<FlutterErrorDetails> errors,
    {bool allowWebViewErrors = false}) {
  final List<FlutterErrorDetails> unexpected = errors.where((e) {
    final String msg = e.exceptionAsString().toLowerCase();
    if (msg.contains('socketexception')) return false;
    if (msg.contains('tls') || msg.contains('timeout')) return false;
    if (allowWebViewErrors) {
      if (msg.contains('webview') || msg.contains('chromium')) return false;
      if (msg.contains('renderer') && msg.contains('crash')) return false;
    }
    return true;
  }).toList();

  expect(unexpected, isEmpty,
      reason: 'Unexpected FlutterErrors: '
          '${unexpected.map((e) => e.exceptionAsString()).join('; ')}');
}
