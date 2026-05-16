import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('App smoke test', () {
    testWidgets('app starts and shows home page with bottom navigation',
        (tester) async {
      app.main();

      // Wait for initialization (up to 60s)
      bool found = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byType(BottomNavigationBar).evaluate().isNotEmpty ||
            find.byType(NavigationBar).evaluate().isNotEmpty) {
          found = true;
          break;
        }
      }

      expect(found, isTrue, reason: 'Home page should load within 60 seconds');
    });

    testWidgets('can switch between tabs without crash', (tester) async {
      app.main();

      // Wait for home page
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byType(BottomNavigationBar).evaluate().isNotEmpty ||
            find.byType(NavigationBar).evaluate().isNotEmpty) {
          break;
        }
      }

      // Find navigation bar icons and tap them
      final navIcons = find.descendant(
        of: find.byType(BottomNavigationBar).evaluate().isNotEmpty
            ? find.byType(BottomNavigationBar)
            : find.byType(NavigationBar),
        matching: find.byType(Icon),
      );

      if (navIcons.evaluate().length >= 2) {
        await tester.tap(navIcons.at(1));
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }

      if (navIcons.evaluate().length >= 3) {
        await tester.tap(navIcons.at(2));
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }

      // No crash means success
      expect(find.byType(Scaffold), findsWidgets);
    });
  });
}
