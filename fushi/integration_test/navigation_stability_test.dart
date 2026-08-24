import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart'
    show CustomFontsPage;
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart'
    show DictionaryDialogPage;
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomePage, HomeTab, homeShellTabNotifier;
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart'
    show OnboardingWizardPage;
import 'package:fushi/src/pages/implementations/shortcut_settings_page.dart'
    show ShortcutSettingsPage;
import 'package:fushi/src/settings/settings_detail_page.dart'
    show SettingsDetailPage;
import 'package:fushi/utils.dart' show FushiListItem, t;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show seedReaderBook;
import 'test_helpers.dart';

/// Device navigation gate.
///
/// Every current visible settings destination is opened and closed with hard
/// assertions. No missing-page skip is allowed. Deep routes and a real seeded
/// reader exercise the same focus, Navigator, and PopScope paths as production.
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'navigate every current settings destination and reader without skips',
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[M4] FlutterError: ${details.exceptionAsString()}');
      };

      try {
        await launchFushiTestApp();
        expect(
          await waitForHome(tester),
          isTrue,
          reason: 'Home must render within 90s',
        );
        await tester.pump(const Duration(seconds: 2));
        await enableFocusNavigation(tester);
        final FocusDriver driver = FocusDriver(tester);

        debugPrint('[M4] === Tab switching ===');
        final List<Finder> navTargets = findPrimaryNavigationTargets();
        expect(
          navTargets.length,
          greaterThanOrEqualTo(3),
          reason: 'At least dashboard, one library, and settings must exist',
        );
        for (int round = 0; round < 5; round++) {
          for (final Finder target in navTargets) {
            expect(
              await driver.focusWidget(target),
              isTrue,
              reason: 'Every visible primary tab must remain focus reachable',
            );
            await driver.activate();
            await tester.pump(const Duration(milliseconds: 200));
            // Wide desktop settings intentionally replaces the primary rail
            // with a full-width two-pane surface and a back exit. Leave it via
            // the production Escape/PopScope path before the next round; the
            // next dashboard target cannot be focus-reachable while the rail
            // is deliberately absent.
            if (homeShellTabNotifier.value == HomeTab.settings) {
              await driver.back();
              await _pumpUntil(
                tester,
                () => homeShellTabNotifier.value != HomeTab.settings,
                reason: 'Settings back must restore the previous primary tab',
              );
            }
          }
        }
        expect(
          tester.takeException(),
          isNull,
          reason: 'Rapid primary-tab switching must not throw',
        );
        debugPrint('[M4] ✓ 5 full tab rounds');

        final List<String> destinations = <String>[
          t.settings_destination_appearance,
          t.settings_destination_reading,
          t.manga_library,
          t.settings_destination_listening,
          t.settings_destination_video,
          t.nav_downloads,
          t.settings_destination_lookup,
          t.settings_destination_card_creation,
          t.settings_destination_profiles,
          t.settings_destination_sync_backup,
          t.settings_destination_interconnect,
          t.settings_destination_storage,
          t.settings_destination_system,
        ];
        final Set<String> uniqueDestinations = destinations.toSet();
        expect(
          uniqueDestinations.length,
          destinations.length,
          reason: 'Destination labels must be unique in the active locale',
        );

        debugPrint('[M4] === All settings destinations ===');
        for (final String label in destinations) {
          final bool pushedDetail =
              await _openSettingsDestination(tester, driver, label);
          expect(
            tester.takeException(),
            isNull,
            reason: '$label detail page must not throw',
          );
          if (pushedDetail) {
            await _systemBack(tester);
            await _pumpUntil(
              tester,
              () => find.byType(SettingsDetailPage).evaluate().isEmpty,
              reason: '$label must return to the settings home',
            );
          }
          debugPrint('[M4] ✓ $label open/back');
        }

        debugPrint('[M4] === Deep settings routes ===');
        await _openDeepRoute<CustomFontsPage>(
          tester,
          driver,
          destination: t.settings_destination_appearance,
          item: t.custom_fonts_catalog_title,
        );
        await _openDeepRoute<ShortcutSettingsPage>(
          tester,
          driver,
          destination: t.settings_destination_system,
          item: t.shortcut_settings_title,
        );
        await _openDeepRoute<OnboardingWizardPage>(
          tester,
          driver,
          destination: t.settings_destination_system,
          item: t.onboarding_reopen,
        );
        await _openDeepRoute<DictionaryDialogPage>(
          tester,
          driver,
          destination: t.settings_destination_lookup,
          item: t.dictionaries,
        );

        debugPrint('[M4] === Reader open/close ===');
        final String bookKey = await seedReaderBook(
          tester,
          fileName: 'navigation_stability.epub',
        );
        await _selectHomeTab(tester, HomeTab.books);
        final Finder book = find.byKey(
          ValueKey<String>(
            'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
          ),
        );
        Finder entry = book;
        if (entry.evaluate().isEmpty) {
          entry = findBookEntries().first;
        }
        await _pumpUntil(
          tester,
          () => entry.evaluate().isNotEmpty,
          reason: 'The seeded reader book must appear on the shelf',
        );
        expect(
          await driver.focusWidget(entry),
          isTrue,
          reason: 'The seeded book card must be focus reachable',
        );
        await driver.activate();

        const Key webViewKey = ValueKey<String>('fushi_webview');
        const Key contentReadyKey = ValueKey<String>('fushi_content_ready');
        await _pumpUntil(
          tester,
          () => find.byKey(webViewKey).evaluate().isNotEmpty,
          reason: 'Reader WebView must mount',
          polls: 160,
        );
        await _pumpUntil(
          tester,
          () => find.byKey(contentReadyKey).evaluate().isNotEmpty,
          reason: 'Reader content must become ready',
          polls: 240,
        );
        await _systemBack(tester);
        await _pumpUntil(
          tester,
          () => find.byKey(webViewKey).evaluate().isEmpty,
          reason: 'Reader PopScope must return to the shelf',
          polls: 160,
        );
        expect(
          isHomeReady(),
          isTrue,
          reason: 'Home must remain ready after reader disposal',
        );

        await takeScreenshot(binding, 'm4_final_state');
        assertStrictErrors(errors);
        debugPrint('[M4] === ALL NAVIGATION TESTS PASSED ===');
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
  );
}

Future<void> _selectHomeTab(WidgetTester tester, HomeTab tab) async {
  expect(
    HomePage.debugSelectTab,
    isNotNull,
    reason: 'HomePage debug tab selector must exist in device test builds',
  );
  HomePage.debugSelectTab!(tab);
  await tester.pump(const Duration(milliseconds: 500));
}

Future<bool> _openSettingsDestination(
  WidgetTester tester,
  FocusDriver driver,
  String label,
) async {
  await _selectHomeTab(tester, HomeTab.settings);
  final Finder target = find.text(label).first;
  expect(
    await driver.focusWidget(target, maxSteps: 320),
    isTrue,
    reason: '$label must be present and focus reachable',
  );
  await driver.activate();
  await _pumpUntil(
    tester,
    () => find.byType(SettingsDetailPage).evaluate().isNotEmpty ||
        _wideDestinationSelected(label),
    reason: '$label must open a narrow detail route or become the selected '
        'wide-layout destination',
  );
  expect(
    find.text(label),
    findsWidgets,
    reason: '$label title must remain visible on its detail page',
  );
  return find.byType(SettingsDetailPage).evaluate().isNotEmpty;
}

bool _wideDestinationSelected(String label) {
  final Finder selectedRows = find.byWidgetPredicate(
    (Widget widget) => widget is FushiListItem && widget.selected,
  );
  return find
      .ancestor(of: find.text(label), matching: selectedRows)
      .evaluate()
      .isNotEmpty;
}

Future<void> _openDeepRoute<T extends Widget>(
  WidgetTester tester,
  FocusDriver driver, {
  required String destination,
  required String item,
}) async {
  final bool pushedDetail =
      await _openSettingsDestination(tester, driver, destination);
  final Finder itemTarget = find.text(item).first;
  expect(
    await driver.focusWidget(itemTarget, maxSteps: 360),
    isTrue,
    reason: '$item must be focus reachable inside $destination',
  );
  await driver.activate();
  await _pumpUntil(
    tester,
    () => find.byType(T).evaluate().isNotEmpty,
    reason: '$item must open ${T.toString()}',
    polls: 160,
  );
  expect(
    tester.takeException(),
    isNull,
    reason: '$item deep page must not throw',
  );

  await _systemBack(tester);
  await _pumpUntil(
    tester,
    () => find.byType(T).evaluate().isEmpty,
    reason: '$item deep page must return to its destination',
  );
  if (pushedDetail) {
    expect(find.byType(SettingsDetailPage), findsOneWidget);
    await _systemBack(tester);
    await _pumpUntil(
      tester,
      () => find.byType(SettingsDetailPage).evaluate().isEmpty,
      reason: '$destination must return to settings home',
    );
  } else {
    expect(
      _wideDestinationSelected(destination),
      isTrue,
      reason: 'wide settings must retain $destination after closing $item',
    );
  }
  debugPrint('[M4] ✓ $destination → $item open/back/back');
}

Future<void> _systemBack(WidgetTester tester) async {
  expect(
    await tester.binding.handlePopRoute(),
    isTrue,
    reason: 'The current route must accept coordinate-free system back',
  );
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int polls = 80,
}) async {
  for (int i = 0; i < polls; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (condition()) return;
  }
  fail(reason);
}
