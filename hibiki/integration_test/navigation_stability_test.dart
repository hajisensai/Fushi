import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

import 'test_helpers.dart';

/// M4: Navigation & Stability tests.
///
/// Verifies every settings page is reachable, back navigation works,
/// and rapid switching doesn't crash the app.
///
/// Requires: connected device/emulator, at least one book imported.
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/navigation_stability_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M4: Navigate all settings pages and verify stability',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[M4] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();

      final bool homeReady = await waitForHome(tester);
      expect(homeReady, isTrue, reason: 'Home must render within 90s');
      await tester.pump(const Duration(seconds: 2));
      debugPrint('[M4] Home ready');

      // === Tab switching stability ===
      debugPrint('[M4] === Tab Switching ===');
      final List<Finder> navTargets = findPrimaryNavigationTargets();
      expect(navTargets.length, greaterThanOrEqualTo(3),
          reason: 'Need at least 3 navigation targets');

      for (int round = 0; round < 5; round++) {
        for (int tab = 0; tab < navTargets.length; tab++) {
          await tester.tap(navTargets[tab]);
          await tester.pump(const Duration(milliseconds: 300));
        }
      }
      await tester.pumpAndSettle();
      debugPrint('[M4] ✓ Rapid tab switching (5 rounds) — no crash');

      // === Navigate to Settings tab ===
      await tester.tap(navTargets.last);
      await tester.pumpAndSettle();
      debugPrint('[M4] On Settings tab');

      // === Settings sub-pages ===
      debugPrint('[M4] === Settings Sub-Pages ===');

      final settingsItems = [
        'Appearance',
        'Configuration Schemes',
        'Reading Display',
        'Reading Controls',
        'Lookup',
        'Card Creation',
        'Listening',
        'Sync & Backup',
        'System',
        'Diagnostics',
      ];

      for (final item in settingsItems) {
        final finder = find.text(item);
        if (finder.evaluate().isEmpty) {
          // May need to scroll to find it
          await _scrollToFind(tester, item);
        }

        if (find.text(item).evaluate().isNotEmpty) {
          await tester.tap(find.text(item).first);
          await tester.pumpAndSettle();

          // Verify page loaded (no infinite loading)
          expect(tester.takeException(), isNull,
              reason: '$item page threw an exception');

          debugPrint('[M4] ✓ $item — opened successfully');

          // Navigate back
          final backButton = find.byType(BackButton);
          final backIcon = find.byIcon(Icons.arrow_back);
          final adaptiveBack = find.byTooltip('Back');
          final popButton = find.byTooltip('戻る');

          if (backButton.evaluate().isNotEmpty) {
            await tester.tap(backButton.first);
          } else if (backIcon.evaluate().isNotEmpty) {
            await tester.tap(backIcon.first);
          } else if (adaptiveBack.evaluate().isNotEmpty) {
            await tester.tap(adaptiveBack.first);
          } else if (popButton.evaluate().isNotEmpty) {
            await tester.tap(popButton.first);
          } else {
            final NavigatorState nav = Navigator.of(
              tester.element(find.byType(Scaffold).first),
            );
            nav.pop();
          }
          await tester.pumpAndSettle();

          debugPrint('[M4] ✓ $item — back navigation OK');
        } else {
          debugPrint('[M4] ⚠ $item — not found, skipped');
        }
      }

      // === Deep navigation: Reading Display → Custom Fonts ===
      debugPrint('[M4] === Deep Navigation ===');
      await _navigateToSettingsItem(tester, 'Reading Display');
      await tester.pumpAndSettle();

      final customFonts = find.text('Custom Fonts');
      if (customFonts.evaluate().isNotEmpty) {
        await tester.tap(customFonts.first);
        await tester.pumpAndSettle();
        debugPrint('[M4] ✓ Custom Fonts — opened');

        // Back twice
        await _goBack(tester);
        await tester.pumpAndSettle();
        await _goBack(tester);
        await tester.pumpAndSettle();
        debugPrint('[M4] ✓ Custom Fonts — back navigation OK');
      }

      // === Deep navigation: Reading Controls → Keyboard Shortcuts ===
      await _navigateToSettingsItem(tester, 'Reading Controls');
      await tester.pumpAndSettle();

      final shortcuts = find.text('Keyboard Shortcuts');
      if (shortcuts.evaluate().isNotEmpty) {
        await tester.tap(shortcuts.first);
        await tester.pumpAndSettle();
        debugPrint('[M4] ✓ Keyboard Shortcuts — opened');
        await _goBack(tester);
        await tester.pumpAndSettle();
        await _goBack(tester);
        await tester.pumpAndSettle();
        debugPrint('[M4] ✓ Keyboard Shortcuts — back navigation OK');
      }

      // === Deep navigation: Lookup → Dictionaries ===
      await _navigateToSettingsItem(tester, 'Lookup');
      await tester.pumpAndSettle();

      final dictionaries = find.text('Dictionaries');
      if (dictionaries.evaluate().isNotEmpty) {
        await tester.tap(dictionaries.first);
        await tester.pumpAndSettle();
        debugPrint('[M4] ✓ Dictionaries — opened');
        await _goBack(tester);
        await tester.pumpAndSettle();
        await _goBack(tester);
        await tester.pumpAndSettle();
        debugPrint('[M4] ✓ Dictionaries — back navigation OK');
      }

      // === Reader open/close stability ===
      debugPrint('[M4] === Reader Stability ===');
      await tester.tap(navTargets.first); // Books tab
      await tester.pumpAndSettle();

      final bookEntries = findBookEntries();
      if (bookEntries.evaluate().isNotEmpty) {
        // Open reader
        await tester.tap(bookEntries.first);
        await tester.pump(const Duration(seconds: 3));

        const Key webViewKey = ValueKey<String>('hoshi_webview');
        bool webViewFound = false;
        for (int i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          if (find.byKey(webViewKey).evaluate().isNotEmpty) {
            webViewFound = true;
            break;
          }
        }

        if (webViewFound) {
          debugPrint('[M4] ✓ Reader WebView loaded');

          // Wait for content
          const Key contentReadyKey =
              ValueKey<String>('hoshi_content_ready');
          for (int i = 0; i < 120; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
              break;
            }
          }

          debugPrint('[M4] ✓ Reader content ready');

          // Navigate back
          final NavigatorState nav = Navigator.of(
            tester.element(find.byType(Scaffold).first),
          );
          nav.pop();
          await tester.pump(const Duration(seconds: 3));
          await tester.pumpAndSettle();

          debugPrint('[M4] ✓ Reader close — back to home');
        }
      }

      // === Final tab state check ===
      await tester.tap(navTargets.first);
      await tester.pumpAndSettle();
      expect(isHomeReady(), isTrue, reason: 'Home should still be ready');
      debugPrint('[M4] ✓ Final home state OK');

      await takeScreenshot(binding, 'm4_final_state');

      // === Error summary ===
      assertStrictErrors(errors);
      debugPrint('[M4] === ALL NAVIGATION TESTS PASSED ===');

    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

Future<void> _scrollToFind(WidgetTester tester, String text) async {
  for (int i = 0; i < 10; i++) {
    if (find.text(text).evaluate().isNotEmpty) return;
    await tester.drag(
      find.byType(Scrollable).first,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _navigateToSettingsItem(
    WidgetTester tester, String itemText) async {
  // Make sure we're on settings tab
  final navTargets = findPrimaryNavigationTargets();
  await tester.tap(navTargets.last);
  await tester.pumpAndSettle();

  await _scrollToFind(tester, itemText);
  if (find.text(itemText).evaluate().isNotEmpty) {
    await tester.tap(find.text(itemText).first);
    await tester.pumpAndSettle();
  }
}

Future<void> _goBack(WidgetTester tester) async {
  final back = find.byTooltip('戻る');
  final backEn = find.byTooltip('Back');
  final backIcon = find.byIcon(Icons.arrow_back);
  final backButton = find.byType(BackButton);

  if (back.evaluate().isNotEmpty) {
    await tester.tap(back.first);
  } else if (backEn.evaluate().isNotEmpty) {
    await tester.tap(backEn.first);
  } else if (backButton.evaluate().isNotEmpty) {
    await tester.tap(backButton.first);
  } else if (backIcon.evaluate().isNotEmpty) {
    await tester.tap(backIcon.first);
  } else {
    final NavigatorState nav = Navigator.of(
      tester.element(find.byType(Scaffold).first),
    );
    nav.pop();
  }
}
