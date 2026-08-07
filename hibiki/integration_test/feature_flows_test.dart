import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/anki_settings_page.dart'
    show AnkiSettingsBody;
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomePage, HomeTab;
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/utils.dart' show t;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show seedDictionary;
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

      // 焦点驱动前置：Tab 遍历在「键盘/手柄焦点导航」实验开关关闭（默认）时被
      // 全局中和为 DoNothingIntent（TODO-112，见 global_navigation.dart），此时
      // focusWidget 永远走不动——先开开关，Tab 遍历才是真实可达性检验（与
      // app_smoke_test / comprehensive_reader_lookup_test 同范式）。
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      await appModel.setExperimentalFocusNavigationEnabled(true);
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      final FocusDriver driver = FocusDriver(tester);
      expect(findPrimaryNavigationTargets().length, greaterThanOrEqualTo(3));

      // 词典 fixture 自给自足：iOS 模拟器上 flutter test 每个文件都是全新
      // app 容器（应用跑完即卸载，数据不跨文件残留），依赖「别的测试种过词典」
      // 的隐式前提在 iOS 上必然落空——曾把 F2 的结果断言降级成永真 ⚠ 警告。
      // 与 comprehensive_reader_lookup_test 同范式：种生成词典，然后硬断言。
      expect(await seedDictionary(tester), isTrue,
          reason: 'generated test dictionary must be installed for F2');

      // 顶层 tab 是条件化列表（video/downloads/games 按开关插入，见 home_page.dart
      // homeActiveTabs），且 index 0 是 dashboard 而非书架——按位置索引取 target
      // 曾把「books」当成词典 tab 驱动，把真实断言降级成了永真警告。改按 tab 身份
      // （图标真值来自生产端 homeNavItemFor）定位，不随开关/顺序漂移。
      final Finder dictionaryTab = findNavTargetForTab(HomeTab.dictionaries);
      final Finder settingsTab = findNavTargetForTab(HomeTab.settings);

      // === F2: Dictionary Search ===
      debugPrint('[M3] === F2: Dictionary Search ===');
      expect(await driver.focusWidget(dictionaryTab), isTrue,
          reason: 'Dictionary tab must be reachable by focus');
      await driver.activate(); // Dictionary tab
      await tester.pump(const Duration(milliseconds: 500));

      // 词典 tab 恒有搜索框（home_dictionary_page 的
      // `home_dictionary_search_field`）；找不到就是真回归，必须硬失败——旧的
      // ⚠ 警告分支曾把「切错 tab」掩盖成顺滑通过。
      final hasSearch = find.byType(TextField).evaluate().isNotEmpty ||
          find.byType(TextFormField).evaluate().isNotEmpty ||
          find.byType(SearchBar).evaluate().isNotEmpty;
      expect(hasSearch, isTrue,
          reason: 'Dictionary tab must render its search field');
      debugPrint('[M3] ✓ Search field found');

      // 搜索词必须是种入 fixture 里真实存在的词条（generated dict 含
      // 「猫/ねこ」的日语词条）；结果为空是硬失败——⚠ 警告曾把「没种词典 /
      // 查询链路断了」一律掩盖成顺滑通过。
      await tester.enterText(findSearchField(), '猫');
      await tester.pump(const Duration(seconds: 5));

      final results = findDictionaryResultEvidence();
      final resultCount = results.evaluate().length;
      debugPrint('[M3] Dictionary results for "猫": $resultCount');
      expect(resultCount, greaterThan(0),
          reason: 'F2: seeded dictionary must return results for 猫 — an '
              'empty result means the seed or the lookup path broke');
      debugPrint('[M3] ✓ F2: Dictionary search returned results');

      // Clear search
      await tester.enterText(findSearchField(), '');
      await tester.pumpAndSettle();

      await takeScreenshot(binding, 'm3_dictionary_search');

      // === F5: Profile Management ===
      debugPrint('[M3] === F5: Profile Management ===');
      expect(await driver.focusWidget(settingsTab), isTrue,
          reason: 'Settings tab must be reachable by focus');
      await driver.activate(); // Settings tab
      await tester.pump(const Duration(milliseconds: 500));

      // 标签用生产 i18n 真值（settings_schema_profiles.dart 同一 key）：硬编码
      // 英文在非英文 locale 的 Mac 上永远找不到，整段被静默跳过。
      final String profilesLabel = t.settings_destination_profiles;
      await _scrollToFind(tester, profilesLabel);
      if (find.text(profilesLabel).evaluate().isNotEmpty) {
        expect(await driver.focusWidget(find.text(profilesLabel).first), isTrue,
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
      // rail 的焦点可达性已在 F2/F5 从干净遍历起点断言过。settings schema 页有
      // 上百个 focusable，从其深处 Tab wrap 回 rail 超出任何合理步数预算——后续
      // 区块的 tab 切换改走确定性测试钩子（与 showBooksTab helper 同一
      // HomePage.debugSelectTab 生产钩子，非坐标点击）。
      await _selectTab(tester, HomeTab.books);

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
      await _selectTab(tester, HomeTab.settings);

      // i18n 真值：en 标签实际是 "Sync & Backup (Experimental)"，旧硬编码
      // 'Sync & Backup' 连英文 locale 都精确匹配不上。
      final String syncLabel = t.settings_destination_sync_backup;
      await _scrollToFind(tester, syncLabel);
      if (find.text(syncLabel).evaluate().isNotEmpty) {
        expect(await driver.focusWidget(find.text(syncLabel).first), isTrue,
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
      await _selectTab(tester, HomeTab.settings);

      final String cardCreationLabel = t.settings_destination_card_creation;
      await _scrollToFind(tester, cardCreationLabel);
      if (find.text(cardCreationLabel).evaluate().isNotEmpty) {
        expect(await driver.focusWidget(find.text(cardCreationLabel).first),
            isTrue,
            reason: 'Card Creation entry must be reachable by focus');
        await driver.activate();
        await tester.pump(const Duration(milliseconds: 500));

        debugPrint('[M3] ✓ Card Creation page opened');

        // Card Creation 已把整段 Anki 正文平铺进本页（settings_schema_
        // card_creation.dart: body → AnkiSettingsBody），页内不再有「Anki 设置」
        // 子页入口行；t.anki_settings_label 只是本分类的 summary 文案。旧的
        // focusWidget(该文本) 在桌面两栏恰好命中主列表里 Card Creation 行自身
        // 的 subtitle（重开同页，伪通过），在 iOS 全页布局上则对不可聚焦的
        // 头部文本耗尽步数。按真实结构断言：打开本页即达 Anki 配置正文。
        expect(find.byType(AnkiSettingsBody), findsOneWidget,
            reason: 'Card Creation page must flat-embed AnkiSettingsBody '
                '(settings_schema_card_creation.dart body)');
        debugPrint('[M3] ✓ F9: Anki settings body embedded (no crash)');
        await takeScreenshot(binding, 'm3_anki_settings');

        await _goBack(tester);
      }

      // === F6: Tag Management (via book long press) ===
      debugPrint('[M3] === F6: Tag Management ===');
      await _selectTab(tester, HomeTab.books);

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
        final tagsChip = find.text(t.tag_label);
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

/// 确定性 tab 切换：走 [HomePage.debugSelectTab] 生产测试钩子（与
/// library_fixture 的 showBooksTab 同一机制），不做坐标点击。rail 的焦点
/// 可达性由 F2/F5 从干净遍历起点专门断言，这里只负责把后续区块带到目标 tab。
Future<void> _selectTab(WidgetTester tester, HomeTab tab) async {
  expect(HomePage.debugSelectTab, isNotNull,
      reason: 'HomePage.debugSelectTab hook must be registered (debug build)');
  HomePage.debugSelectTab!(tab);
  await tester.pump(const Duration(milliseconds: 500));
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
