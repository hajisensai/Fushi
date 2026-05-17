import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

const List<IconData> _knownTabIcons = [
  Icons.menu_book,
  Icons.search,
  Icons.tune,
];

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

    try {
      app.main();
      await _waitForHomeReady(tester);

      await _takeScreenshotSafe(binding, 'home_books_tab');

      final List<Finder> navIcons = _findNavIcons();
      final int tabCount = navIcons.length;
      debugPrint('[test] Found $tabCount navigation icons');
      expect(tabCount, greaterThanOrEqualTo(2),
          reason: 'App should have at least 2 navigation icons');

      // --- Tab 1: Dictionary ---
      await tester.tap(navIcons[1]);
      await tester.pump(const Duration(seconds: 3));

      expect(find.byType(Scaffold), findsWidgets,
          reason: 'Dictionary tab should render');
      await _takeScreenshotSafe(binding, 'tab_dictionary');

      final bool hasSearch = find.byType(TextField).evaluate().isNotEmpty ||
          find.byType(TextFormField).evaluate().isNotEmpty ||
          find.byType(SearchBar).evaluate().isNotEmpty;
      debugPrint('[test] Dictionary tab has search field: $hasSearch');

      // --- Tab 2: Settings ---
      if (tabCount >= 3) {
        await tester.tap(navIcons[2]);
        await tester.pump(const Duration(seconds: 3));

        expect(find.byType(Scaffold), findsWidgets,
            reason: 'Settings tab should render');
        await _takeScreenshotSafe(binding, 'tab_settings');

        final bool hasListTiles =
            find.byType(ListTile).evaluate().isNotEmpty;
        debugPrint('[test] Settings tab has ListTiles: $hasListTiles');

        final Finder scrollable = find.byType(Scrollable);
        if (scrollable.evaluate().isNotEmpty) {
          await tester.drag(scrollable.first, const Offset(0, -300));
          await tester.pump(const Duration(seconds: 1));
          await _takeScreenshotSafe(binding, 'tab_settings_scrolled');
        }
      }

      // --- Return to first tab ---
      await tester.tap(navIcons[0]);
      await tester.pump(const Duration(seconds: 3));

      expect(find.byType(Scaffold), findsWidgets,
          reason: 'Books tab should render after round-trip navigation');
      await _takeScreenshotSafe(binding, 'home_books_return');

      // --- Rapid tab switching stability ---
      debugPrint('[test] Starting rapid tab switching (20 cycles)');
      for (int i = 0; i < 20; i++) {
        final int tabIndex = i % navIcons.length;
        final Finder target = navIcons[tabIndex];
        if (target.evaluate().isEmpty) continue;
        await tester.tap(target);
        await tester.pump(const Duration(milliseconds: 200));
      }

      await tester.pump(const Duration(seconds: 2));

      expect(find.byType(Scaffold), findsWidgets,
          reason: 'App should survive rapid tab switching');

      _assertNoUnexpectedErrors(errors);
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
    if (find.byIcon(Icons.menu_book).evaluate().isNotEmpty) {
      debugPrint('[test] Home ready at iteration $i (${i * 500}ms)');
      await tester.pump(const Duration(seconds: 1));
      return;
    }
    if (i > 0 && i % 20 == 0) {
      final bool hasScaffold =
          find.byType(Scaffold).evaluate().isNotEmpty;
      debugPrint(
          '[test] Still waiting for home... iteration $i, scaffold=$hasScaffold');
    }
  }
  debugPrint('[test] Home not ready after 90s');
  fail('Home page did not show navigation icons within 90s');
}

List<Finder> _findNavIcons() {
  final List<Finder> found = [];
  for (final IconData iconData in _knownTabIcons) {
    final Finder f = find.byIcon(iconData);
    if (f.evaluate().isNotEmpty) {
      found.add(f);
    }
  }
  return found;
}

Future<void> _takeScreenshotSafe(
    IntegrationTestWidgetsFlutterBinding binding, String name) async {
  try {
    await binding.takeScreenshot(name);
    debugPrint('[test] Screenshot saved: $name');
  } catch (e) {
    debugPrint('[test] Screenshot skipped ($name): $e');
  }
}

void _assertNoUnexpectedErrors(List<FlutterErrorDetails> errors) {
  final List<FlutterErrorDetails> unexpected = errors.where((e) {
    final String msg = e.exceptionAsString().toLowerCase();
    if (msg.contains('webview') || msg.contains('chromium')) return false;
    if (msg.contains('renderer') && msg.contains('crash')) return false;
    if (msg.contains('socketexception')) return false;
    if (msg.contains('tls') || msg.contains('timeout')) return false;
    return true;
  }).toList();

  expect(unexpected, isEmpty,
      reason: 'Unexpected FlutterErrors: '
          '${unexpected.map((e) => e.exceptionAsString()).join('; ')}');
}
