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
import 'package:fushi/src/settings/settings_destination.dart'
    show SettingsDestinationId;
import 'package:fushi/src/settings/settings_detail_page.dart'
    show SettingsDetailPage;
import 'package:fushi/utils.dart' show t;

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

        // 每条 destination 必须带 id：断言只认「详情面板的身份」，不认「这一行
        // 被高亮」——后者在宽屏第一帧就为真（settings_home_page 无条件把
        // _selectedDestinationId 落到 destinations.first = appearance），和有没有
        // 发生过导航完全无关。
        final List<_SettingsDestinationCase> destinations =
            <_SettingsDestinationCase>[
          (
            id: SettingsDestinationId.appearance,
            label: t.settings_destination_appearance,
          ),
          (
            id: SettingsDestinationId.reading,
            label: t.settings_destination_reading,
          ),
          (id: SettingsDestinationId.manga, label: t.manga_library),
          (
            id: SettingsDestinationId.listening,
            label: t.settings_destination_listening,
          ),
          (
            id: SettingsDestinationId.video,
            label: t.settings_destination_video,
          ),
          (id: SettingsDestinationId.downloads, label: t.nav_downloads),
          (
            id: SettingsDestinationId.lookup,
            label: t.settings_destination_lookup,
          ),
          (
            id: SettingsDestinationId.cardCreation,
            label: t.settings_destination_card_creation,
          ),
          (
            id: SettingsDestinationId.profiles,
            label: t.settings_destination_profiles,
          ),
          (
            id: SettingsDestinationId.syncBackup,
            label: t.settings_destination_sync_backup,
          ),
          (
            id: SettingsDestinationId.interconnect,
            label: t.settings_destination_interconnect,
          ),
          (
            id: SettingsDestinationId.storage,
            label: t.settings_destination_storage,
          ),
          (
            id: SettingsDestinationId.system,
            label: t.settings_destination_system,
          ),
        ];
        final Set<String> uniqueDestinations =
            destinations.map((_SettingsDestinationCase c) => c.label).toSet();
        expect(
          uniqueDestinations.length,
          destinations.length,
          reason: 'Destination labels must be unique in the active locale',
        );

        // 把选中项挪到列表最后一项，这样第一条（appearance）的「打开前它不该已
        // 经在显示」前置条件才是真检查，而不是被默认选中蒙混过关。
        await _openSettingsDestination(
          tester,
          driver,
          destinations.last,
          requireTransition: false,
        );
        if (find.byType(SettingsDetailPage).evaluate().isNotEmpty) {
          await _systemBack(tester);
          await _pumpUntil(
            tester,
            () => find.byType(SettingsDetailPage).evaluate().isEmpty,
            reason: 'priming destination must return to the settings home',
          );
        }

        debugPrint('[M4] === All settings destinations ===');
        for (final _SettingsDestinationCase destination in destinations) {
          final bool pushedDetail =
              await _openSettingsDestination(tester, driver, destination);
          expect(
            tester.takeException(),
            isNull,
            reason: '${destination.label} detail page must not throw',
          );
          if (pushedDetail) {
            await _systemBack(tester);
            await _pumpUntil(
              tester,
              () => find.byType(SettingsDetailPage).evaluate().isEmpty,
              reason: '${destination.label} must return to the settings home',
            );
          }
          debugPrint('[M4] ✓ ${destination.label} open/back');
        }

        debugPrint('[M4] === Deep settings routes ===');
        await _openDeepRoute<CustomFontsPage>(
          tester,
          driver,
          destination: (
            id: SettingsDestinationId.appearance,
            label: t.settings_destination_appearance,
          ),
          item: t.custom_fonts_catalog_title,
        );
        await _openDeepRoute<ShortcutSettingsPage>(
          tester,
          driver,
          destination: (
            id: SettingsDestinationId.system,
            label: t.settings_destination_system,
          ),
          item: t.shortcut_settings_title,
        );
        await _openDeepRoute<OnboardingWizardPage>(
          tester,
          driver,
          destination: (
            id: SettingsDestinationId.system,
            label: t.settings_destination_system,
          ),
          item: t.onboarding_reopen,
        );
        await _openDeepRoute<DictionaryDialogPage>(
          tester,
          driver,
          destination: (
            id: SettingsDestinationId.lookup,
            label: t.settings_destination_lookup,
          ),
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

/// 一条 settings 分类用例：id 用于断言**详情面板身份**，label 只用于聚焦这一行。
typedef _SettingsDestinationCase = ({SettingsDestinationId id, String label});

Future<bool> _openSettingsDestination(
  WidgetTester tester,
  FocusDriver driver,
  _SettingsDestinationCase destination, {
  bool requireTransition = true,
}) async {
  final String label = destination.label;
  await _selectHomeTab(tester, HomeTab.settings);
  if (requireTransition) {
    // 前置条件：目标详情面板**还没在显示**。没有这一条，宽屏下第一条
    // （appearance）的等待条件在进入设置的第一帧就已满足，整个用例退化成
    // 「这一行存在且能聚焦」——activate() 完全不做事也照样绿。
    expect(
      _settingsDestinationShown(destination.id),
      isFalse,
      reason: '$label must not already be the shown destination before it is '
          'activated, otherwise this case asserts nothing',
    );
  }
  final Finder target = find.text(label).first;
  expect(
    await driver.focusWidget(target, maxSteps: 320),
    isTrue,
    reason: '$label must be present and focus reachable',
  );
  await driver.activate();
  await _pumpUntil(
    tester,
    () => _settingsDestinationShown(destination.id),
    reason: '$label must open its own detail page (narrow) or its own wide '
        'detail pane — a highlighted row is not proof of navigation',
  );
  expect(
    find.text(label),
    findsWidgets,
    reason: '$label title must remain visible on its detail page',
  );
  return find.byType(SettingsDetailPage).evaluate().isNotEmpty;
}

/// 该分类的详情内容是否真的在屏上——按**身份**判，不按「哪一行高亮」判。
///
/// - 窄屏：`SettingsDetailPage` 自带 `destination`（settings_detail_page.dart）。
/// - 宽屏：详情面板外层是 `KeyedSubtree(key: ValueKey<SettingsDestinationId>(id))`
///   （settings_home_page.dart）。
bool _settingsDestinationShown(SettingsDestinationId id) {
  final bool pushedDetail = find
      .byWidgetPredicate(
        (Widget widget) =>
            widget is SettingsDetailPage && widget.destination.id == id,
      )
      .evaluate()
      .isNotEmpty;
  if (pushedDetail) return true;
  return find.byKey(ValueKey<SettingsDestinationId>(id)).evaluate().isNotEmpty;
}

Future<void> _openDeepRoute<T extends Widget>(
  WidgetTester tester,
  FocusDriver driver, {
  required _SettingsDestinationCase destination,
  required String item,
}) async {
  // 深路由用例连着开同一个分类两次（system → 快捷键 / system → 新手引导），
  // 宽屏下第二次目标本来就在显示，所以这里不要求「必须发生切换」——真正的断言
  // 是 find.byType(T)，它不会恒真。
  final bool pushedDetail = await _openSettingsDestination(
    tester,
    driver,
    destination,
    requireTransition: false,
  );
  final Finder itemTarget = find.text(item).first;
  expect(
    await driver.focusWidget(itemTarget, maxSteps: 360),
    isTrue,
    reason: '$item must be focus reachable inside ${destination.label}',
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
  final String destinationLabel = destination.label;
  if (pushedDetail) {
    expect(find.byType(SettingsDetailPage), findsOneWidget);
    await _systemBack(tester);
    await _pumpUntil(
      tester,
      () => find.byType(SettingsDetailPage).evaluate().isEmpty,
      reason: '$destinationLabel must return to settings home',
    );
  } else {
    expect(
      _settingsDestinationShown(destination.id),
      isTrue,
      reason: 'wide settings must retain the $destinationLabel detail pane '
          'after closing $item',
    );
  }
  debugPrint('[M4] ✓ $destinationLabel → $item open/back/back');
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
