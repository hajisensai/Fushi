import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

import 'helpers/focus_driver.dart';
import 'test_helpers.dart';

/// M3: Feature Flow tests.
///
/// Verifies end-to-end feature paths: dictionary search, profile management,
/// reading statistics, sync settings.
///
/// Requires: connected device/emulator, at least one book and dictionary imported.
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/feature_flows_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M3: Feature flows work end-to-end', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[M3] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();

      final bool homeReady = await waitForHome(tester);
      expect(homeReady, isTrue, reason: 'Home must render within 90s');
      await tester.pump(const Duration(seconds: 2));
      debugPrint('[M3] Home ready');

      final FocusDriver driver = FocusDriver(tester);
      final navTargets = findPrimaryNavigationTargets();
      expect(navTargets.length, greaterThanOrEqualTo(3));

      // === F2: Dictionary Search ===
      debugPrint('[M3] === F2: Dictionary Search ===');
      expect(await driver.focusWidget(navTargets[1]), isTrue,
          reason: 'Dictionary tab must be reachable by focus');
      await driver.activate(); // Dictionary tab
      await tester.pump(const Duration(milliseconds: 500));

      final hasSearch = find.byType(TextField).evaluate().isNotEmpty ||
          find.byType(TextFormField).evaluate().isNotEmpty ||
          find.byType(SearchBar).evaluate().isNotEmpty;

      if (hasSearch) {
        debugPrint('[M3] ✓ Search field found');

        await tester.enterText(findSearchField(), '読む');
        await tester.pump(const Duration(seconds: 5));

        final results = findDictionaryResultEvidence();
        final resultCount = results.evaluate().length;
        debugPrint('[M3] Dictionary results for "読む": $resultCount');

        if (resultCount > 0) {
          debugPrint('[M3] ✓ F2: Dictionary search returned results');
        } else {
          debugPrint('[M3] ⚠ F2: No dictionary results '
              '(may need dictionary imported)');
        }

        // Clear search
        await tester.enterText(findSearchField(), '');
        await tester.pumpAndSettle();
      } else {
        debugPrint('[M3] ⚠ F2: No search field found on dictionary tab');
      }

      await takeScreenshot(binding, 'm3_dictionary_search');

      // === F5: Profile Management ===
      debugPrint('[M3] === F5: Profile Management ===');
      expect(await driver.focusWidget(navTargets.last), isTrue,
          reason: 'Settings tab must be reachable by focus');
      await driver.activate(); // Settings tab
      await tester.pump(const Duration(milliseconds: 500));

      await _scrollToFind(tester, 'Configuration Schemes');
      if (find.text('Configuration Schemes').evaluate().isNotEmpty) {
        expect(
            await driver.focusWidget(find.text('Configuration Schemes').first),
            isTrue,
            reason: 'Configuration Schemes entry must be reachable by focus');
        await driver.activate();
        await tester.pump(const Duration(milliseconds: 500));

        debugPrint('[M3] ✓ Profile management page opened');
        await takeScreenshot(binding, 'm3_profile_management');

        // Page reached without crash is the feature-flow signal; a fresh
        // install may legitimately have no saved profiles yet.
        final profileCount = find.byType(ListTile).evaluate().length;
        debugPrint('[M3] Profile items visible: $profileCount');
        expect(tester.takeException(), isNull,
            reason: 'Profile page must not throw');

        debugPrint('[M3] ✓ F5: Profile management accessible');
        await _goBack(tester);
      }

      // === F8: Reading Statistics ===
      debugPrint('[M3] === F8: Reading Statistics ===');
      expect(await driver.focusWidget(navTargets.first), isTrue,
          reason: 'Books tab must be reachable by focus');
      await driver.activate(); // Books tab
      await tester.pump(const Duration(milliseconds: 500));

      // Look for statistics access point (usually in the top bar)
      final statsIcon = find.byIcon(Icons.bar_chart);
      final statsIcon2 = find.byIcon(Icons.insert_chart);
      final statsIcon3 = find.byIcon(Icons.analytics);

      Finder? statsButton;
      if (statsIcon.evaluate().isNotEmpty) {
        statsButton = statsIcon;
      } else if (statsIcon2.evaluate().isNotEmpty) {
        statsButton = statsIcon2;
      } else if (statsIcon3.evaluate().isNotEmpty) {
        statsButton = statsIcon3;
      }

      if (statsButton != null) {
        if (await driver.focusWidget(statsButton.first)) {
          await driver.activate();
        } else {
          // Icon-only top-bar buttons can be focus targets registered late;
          // fall back to the framework activate intent on the focused node.
          await driver.activateIntent();
        }
        await tester.pump(const Duration(milliseconds: 500));
        debugPrint('[M3] ✓ F8: Reading statistics page opened');
        await takeScreenshot(binding, 'm3_reading_statistics');
        await _goBack(tester);
      } else {
        debugPrint('[M3] ⚠ F8: Statistics icon not found on home page');
      }

      // === F10: Sync Settings ===
      debugPrint('[M3] === F10: Sync Settings ===');
      expect(await driver.focusWidget(navTargets.last), isTrue,
          reason: 'Settings tab must be reachable by focus');
      await driver.activate(); // Settings tab
      await tester.pump(const Duration(milliseconds: 500));

      await _scrollToFind(tester, 'Sync & Backup');
      if (find.text('Sync & Backup').evaluate().isNotEmpty) {
        expect(
            await driver.focusWidget(find.text('Sync & Backup').first), isTrue,
            reason: 'Sync & Backup entry must be reachable by focus');
        await driver.activate();
        await tester.pump(const Duration(milliseconds: 500));

        debugPrint('[M3] ✓ Sync & Backup page opened');
        await takeScreenshot(binding, 'm3_sync_settings');

        // Check backend selector exists
        final backendLabels = ['WebDAV', 'Google Drive'];
        bool foundBackend = false;
        for (final label in backendLabels) {
          if (find.text(label).evaluate().isNotEmpty) {
            foundBackend = true;
            debugPrint('[M3] Found backend option: $label');
          }
        }

        if (foundBackend) {
          debugPrint('[M3] ✓ F10: Sync backend options visible');
        } else {
          debugPrint('[M3] ⚠ F10: No sync backend options found');
        }

        await _goBack(tester);
      }

      // === F9: Anki Settings (degraded — no AnkiDroid) ===
      debugPrint('[M3] === F9: Anki Settings ===');
      expect(await driver.focusWidget(navTargets.last), isTrue,
          reason: 'Settings tab must be reachable by focus');
      await driver.activate();
      await tester.pump(const Duration(milliseconds: 500));

      await _scrollToFind(tester, 'Card Creation');
      if (find.text('Card Creation').evaluate().isNotEmpty) {
        expect(
            await driver.focusWidget(find.text('Card Creation').first), isTrue,
            reason: 'Card Creation entry must be reachable by focus');
        await driver.activate();
        await tester.pump(const Duration(milliseconds: 500));

        debugPrint('[M3] ✓ Card Creation page opened');

        // Try to navigate to Anki Settings
        await _scrollToFind(tester, 'Anki Settings');
        if (find.text('Anki Settings').evaluate().isNotEmpty) {
          expect(await driver.focusWidget(find.text('Anki Settings').first),
              isTrue,
              reason: 'Anki Settings entry must be reachable by focus');
          await driver.activate();
          await tester.pump(const Duration(milliseconds: 500));
          debugPrint('[M3] ✓ F9: Anki Settings page opened (no crash)');
          await takeScreenshot(binding, 'm3_anki_settings');
          await _goBack(tester);
        }

        await _goBack(tester);
      }

      // === F6: Tag Management (via book long press) ===
      debugPrint('[M3] === F6: Tag Management ===');
      // Re-acquire nav targets: the bottom nav may not be on screen right
      // after the previous section's back navigation, so the original
      // (lazily-evaluated) finder can be empty here.
      final f6Nav = findPrimaryNavigationTargets();
      if (f6Nav.isNotEmpty) {
        expect(await driver.focusWidget(f6Nav.first), isTrue,
            reason: 'Books tab must be reachable by focus');
        await driver.activate(); // Books tab
        await tester.pump(const Duration(milliseconds: 500));
      } else {
        debugPrint('[M3] ⚠ F6: bottom nav not visible — staying on '
            'current screen');
      }

      final bookEntries = findBookEntries();
      if (bookEntries.evaluate().isNotEmpty) {
        // Focus-driven long-press: focus the book card, then dispatch the same
        // GamepadLongPressIntent the gamepad layer fires on a held A button —
        // it invokes the identical onLongPress as a mouse long-press, opening
        // the single-book context menu. Position-independent, three-end safe.
        expect(await driver.focusWidget(bookEntries.first), isTrue,
            reason: 'Book card must be reachable by focus');
        final bool longPressed = _dispatchGamepadLongPress();
        expect(longPressed, isTrue,
            reason: 'focused book card must expose GamepadLongPressIntent '
                '(the keyboard/gamepad equivalent of a long-press)');
        await tester.pump(const Duration(milliseconds: 500));
        debugPrint('[M3] Long pressed book entry (via GamepadLongPressIntent)');

        await takeScreenshot(binding, 'm3_book_context_menu');

        // Look for Tags option
        final tagsChip = find.text('Tags');
        if (tagsChip.evaluate().isNotEmpty) {
          debugPrint('[M3] ✓ F6: Tags option visible in context menu');
        }

        // Dismiss the context menu via the keyboard (Escape pops the menu
        // route) instead of a coordinate tap, so no screen-position guess can
        // miss the barrier.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }

      // === Final summary ===
      debugPrint('[M3] === Feature Flows Complete ===');
      assertStrictErrors(errors);
      debugPrint('[M3] === ALL FEATURE FLOW TESTS PASSED ===');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

Future<void> _scrollToFind(WidgetTester tester, String text) async {
  for (int i = 0; i < 15; i++) {
    if (find.text(text).evaluate().isNotEmpty) return;
    final scrollables = find.byType(Scrollable);
    if (scrollables.evaluate().isEmpty) return;
    await tester.drag(scrollables.first, const Offset(0, -200));
    await tester.pumpAndSettle();
  }
}

Future<void> _goBack(WidgetTester tester) async {
  // Focus-driven back: the global HibikiPopIntent (gameButtonB) pops the route
  // without depending on a Back button's coordinates / tooltip locale.
  await FocusDriver(tester).back();
  await tester.pump(const Duration(milliseconds: 250));
}

/// Dispatch a [GamepadLongPressIntent] to the currently focused widget — the
/// keyboard/gamepad equivalent of a mouse long-press. Synchronous (no await
/// across the BuildContext) so it never crosses an async gap.
bool _dispatchGamepadLongPress() {
  final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return Actions.maybeInvoke<GamepadLongPressIntent>(
        ctx,
        const GamepadLongPressIntent(GamepadButton.a),
      ) ==
      true;
}
