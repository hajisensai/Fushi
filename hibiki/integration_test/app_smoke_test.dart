import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app starts and initializes without crash',
      (WidgetTester tester) async {
    // Capture FlutterError instead of letting it fail the test.
    // WebView renderer crashes on emulator trigger spurious errors.
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[test] FlutterError caught: ${details.exceptionAsString()}');
    };

    try {
      app.main();

      // Wait for app initialization (up to 90s).
      // Look for Scaffold as the most basic sign of a rendered app.
      bool rendered = false;
      for (int i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byType(Scaffold).evaluate().isNotEmpty) {
          rendered = true;
          break;
        }
      }

      expect(rendered, isTrue,
          reason: 'App should render at least one Scaffold within 90 seconds');

      // If we find navigation, try switching tabs
      final bool hasBottomNav =
          find.byType(BottomNavigationBar).evaluate().isNotEmpty;
      final bool hasNavBar = find.byType(NavigationBar).evaluate().isNotEmpty;

      if (hasBottomNav || hasNavBar) {
        final Finder navBar = hasBottomNav
            ? find.byType(BottomNavigationBar)
            : find.byType(NavigationBar);

        final Finder navIcons = find.descendant(
          of: navBar,
          matching: find.byType(Icon),
        );

        if (navIcons.evaluate().length >= 2) {
          await tester.tap(navIcons.at(1));
          await tester.pump(const Duration(seconds: 3));
        }

        if (navIcons.evaluate().isNotEmpty) {
          await tester.tap(navIcons.at(0));
          await tester.pump(const Duration(seconds: 3));
        }
      }

      // App survived without fatal crash
      expect(find.byType(Scaffold), findsWidgets);

      // Filter out known emulator-only errors (WebView renderer, chromium,
      // network timeouts) and fail on unexpected app-level errors.
      final List<FlutterErrorDetails> unexpectedErrors = errors.where((e) {
        final String msg = e.exceptionAsString().toLowerCase();
        if (msg.contains('webview') || msg.contains('chromium')) return false;
        if (msg.contains('renderer') && msg.contains('crash')) return false;
        if (msg.contains('socketexception')) return false;
        if (msg.contains('tls') || msg.contains('timeout')) return false;
        return true;
      }).toList();

      expect(unexpectedErrors, isEmpty,
          reason: 'App produced unexpected FlutterErrors: '
              '${unexpectedErrors.map((e) => e.exceptionAsString()).join('; ')}');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
