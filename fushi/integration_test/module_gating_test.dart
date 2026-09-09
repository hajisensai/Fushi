// 「功能模块」端到端：关掉除书架外的全部模块之后，**首页与设置页里属于它们的入口
// 一并消失**（用户拍板的隐藏强度：「看不见也到不了」）。
//
// 这条跑的是真 app、真持久化路径（`setModuleEnabled` 与设置页开关同一真值），
// 断言的是真渲染树，并落屏幕像素证据。schema 层的收缩另有纯 widget 用例
// （`test/settings/settings_module_gating_test.dart`）；这里补的是「整条壳装起来
// 之后确实是这样」。
//
// 跑法（离屏、不抢焦点）：
//   .\tool\run_windows_itest.ps1 integration_test\module_gating_test.dart
//
// 不打开任何媒体（无 openMedia），故纯离屏即可，不需要 -Visible。
// Windows 离屏 runner 会把 APPDATA 重定向到隔离根（跑的不是用户真库），但同一份测试
// 三端可跑（模拟器 / Mac 跨机 都在真库上）：进场先快照 11 个模块的原值，finally 里
// 逐个还原，绝不留副作用。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/settings/settings_schema_card_creation.dart';
import 'package:fushi/src/settings/settings_schema_downloads.dart';
import 'package:fushi/src/settings/settings_schema_game.dart';
import 'package:fushi/src/settings/settings_schema_listening.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart';
import 'package:fushi/src/settings/settings_schema_manga.dart';
import 'package:fushi/src/settings/settings_schema_profiles.dart';
import 'package:fushi/src/settings/settings_schema_reading.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/settings/settings_schema_storage.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/settings/settings_schema_tracking.dart';
import 'package:fushi/src/settings/settings_schema_video.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi/utils.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 抓当前帧里所有可见的 [Text] 文案（去空去重、保序）。截图是像素证据，这份是
/// 可 diff 的文本证据，也是下面断言的观测面。
List<String> visibleTexts(WidgetTester tester) =>
    _textsOf(tester, find.byType(Text).evaluate().toList(growable: false));

/// 设置页宽布局是 master-detail：左侧一级分类列表 + 右侧当前分类正文。本测试要断言
/// 的是**左侧列表**，必须把右侧正文排除掉——「外观 › 功能模块」里那 11 个开关行的
/// 标题**故意**与分类标题同字（`settings_module_labels_match_nav_test` 钉的就是这条
/// 纪律），整帧扫文案会把「还留着一个叫『视频』的开关」误判成「『视频』分类没藏掉」。
/// 而那个开关正是用户把模块开回来的唯一入口，它必须留着。
///
/// 右侧正文的身份是 `KeyedSubtree(key: ValueKey<SettingsDestinationId>(selected.id))`
/// （`settings_home_page.dart` 用它按 destination 作废子树）。按 Element 求差集，不是
/// 按字符串求差——同一个词可能两边都出现，减字符串会把真泄漏也一起抹掉。
List<String> visibleTextsOutsideDetailPane(WidgetTester tester) {
  final Set<Element> all = find.byType(Text).evaluate().toSet();
  final Finder detailPane = find.byWidgetPredicate(
    (Widget w) => w is KeyedSubtree && w.key is ValueKey<SettingsDestinationId>,
  );
  if (detailPane.evaluate().isNotEmpty) {
    all.removeAll(
      find.descendant(of: detailPane, matching: find.byType(Text)).evaluate(),
    );
  }
  // find 的遍历序即渲染树序，保序即可 diff。
  return _textsOf(
    tester,
    find.byType(Text).evaluate().where(all.contains).toList(growable: false),
  );
}

List<String> _textsOf(WidgetTester tester, List<Element> elements) {
  final List<String> out = <String>[];
  for (final Element element in elements) {
    final String? data = (element.widget as Text).data;
    if (data == null) continue;
    final String trimmed = data.trim();
    if (trimmed.isEmpty) continue;
    if (out.contains(trimmed)) continue;
    out.add(trimmed);
  }
  return out;
}

/// 每条设置一级分类的标题，取自**各自的 builder**——不在本文件抄第二份字面量，
/// 分类改名时这里自动跟着改（同 `settings_module_labels_match_nav_test` 的取值纪律）。
Map<SettingsDestinationId, String> destinationTitles() {
  final List<SettingsDestination> all = <SettingsDestination>[
    buildAppearanceDestination(),
    buildReadingDestination(),
    buildMangaDestination(),
    buildListeningDestination(),
    buildVideoDestination(),
    buildMediaTrackingDestination(),
    buildDownloadsDestination(),
    buildServicesDestination(),
    buildGameDestination(),
    buildLookupDestination(),
    buildCardCreationDestination(),
    buildProfilesDestination(),
    buildSyncBackupDestination(),
    buildInterconnectDestination(),
    buildStorageDestination(),
    buildSystemDestination(),
  ];
  return <SettingsDestinationId, String>{
    for (final SettingsDestination d in all) d.id: d.title,
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('只留书架：首页筛选条与设置一级分类都跟着收缩', (WidgetTester tester) async {
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      debugPrint(
        '[module-gating] FlutterError: ${details.exceptionAsString()}',
      );
    };

    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));

      final AppModel appModel = await readyAppModel(tester);
      final Map<ModuleId, bool> original = <ModuleId, bool>{
        for (final ModuleId module in ModuleId.values)
          module: appModel.moduleEnabled(module),
      };
      final Map<SettingsDestinationId, String> titles = destinationTitles();

      try {
        // ── 基线：全部模块打开 ──────────────────────────────────────────────
        for (final ModuleId module in ModuleId.values) {
          await appModel.setModuleEnabled(module, true);
        }
        await tester.pump(const Duration(seconds: 1));

        HomePage.debugSelectTab?.call(HomeTab.home);
        await tester.pump(const Duration(seconds: 2));
        final List<String> homeBefore = visibleTexts(tester);
        expect(
          (await captureFlutterFrame(
            tester,
            'module-gating-01-home-all-on',
          )).saved,
          isTrue,
        );
        debugPrint('[module-gating] 首页(全开) 文案: $homeBefore');

        HomePage.debugSelectTab?.call(HomeTab.settings);
        await tester.pump(const Duration(seconds: 2));
        final List<String> settingsBefore = visibleTextsOutsideDetailPane(
          tester,
        );
        expect(
          (await captureFlutterFrame(
            tester,
            'module-gating-02-settings-all-on',
          )).saved,
          isTrue,
        );
        debugPrint('[module-gating] 设置主页(全开) 左侧分类: $settingsBefore');

        // ── 只留书架 ───────────────────────────────────────────────────────
        for (final ModuleId module in ModuleId.values) {
          if (module == ModuleId.books) continue;
          await appModel.setModuleEnabled(module, false);
        }
        await tester.pump(const Duration(seconds: 2));

        final List<String> settingsAfter = visibleTextsOutsideDetailPane(
          tester,
        );
        expect(
          (await captureFlutterFrame(
            tester,
            'module-gating-03-settings-books-only',
          )).saved,
          isTrue,
        );
        debugPrint('[module-gating] 设置主页(只留书架) 左侧分类: $settingsAfter');

        // 被关模块名下的分类：一条都不许留。
        //
        // 只对**基线帧里真的渲染出来过**的标题断言——设置主页是滚动列表，视口外的
        // 分类本来就不在树里，拿它们断言只会把「没滚到」当成「已隐藏」（假绿）或
        // 相反（假红）。断言覆盖了几条会打印出来，覆盖数掉到 0 说明这条测试已经
        // 空转，得先修观测面。
        final List<String> gatedChecked = <String>[];
        final List<String> leaked = <String>[];
        final List<String> alwaysOnChecked = <String>[];
        final List<String> vanished = <String>[];
        titles.forEach((SettingsDestinationId id, String title) {
          final ModuleId? owner = moduleOfSettingsDestination(id);
          if (!settingsBefore.contains(title)) return;
          if (owner == null) {
            alwaysOnChecked.add(title);
            if (!settingsAfter.contains(title)) vanished.add('$title($id)');
            return;
          }
          if (owner == ModuleId.books) return;
          gatedChecked.add(title);
          if (settingsAfter.contains(title)) leaked.add('$title($id)');
        });
        debugPrint(
          '[module-gating] 断言覆盖：被关分类 $gatedChecked / 恒在分类 $alwaysOnChecked',
        );
        expect(
          gatedChecked,
          isNotEmpty,
          reason: '基线帧里一条受门控的分类都没渲染出来，本测试没有观测面（假绿）',
        );
        expect(
          leaked,
          isEmpty,
          reason:
              '这些分类的模块已关，设置主页左侧列表却还列着：$leaked'
              '（右侧「外观 › 功能模块」里的同名开关不算——那是把模块开回来的唯一'
              '入口，已按 detail pane 排除）',
        );
        expect(
          vanished,
          isEmpty,
          reason: '恒在分类被连坐藏掉了：$vanished（外观/阅读/查词/配置方案/存储/系统 不属任何模块）',
        );

        // ── 首页 dashboard 的筛选条 ────────────────────────────────────────
        HomePage.debugSelectTab?.call(HomeTab.home);
        await tester.pump(const Duration(seconds: 2));
        final List<String> homeAfter = visibleTexts(tester);
        expect(
          (await captureFlutterFrame(
            tester,
            'module-gating-04-home-books-only',
          )).saved,
          isTrue,
        );
        debugPrint('[module-gating] 首页(只留书架) 文案: $homeAfter');

        for (final String label in <String>[
          t.home_filter_watch,
          t.home_filter_game,
        ]) {
          if (!homeBefore.contains(label)) continue;
          expect(
            homeAfter,
            isNot(contains(label)),
            reason: '视频/游戏模块已关，首页筛选条却还有「$label」档',
          );
        }
      } finally {
        for (final MapEntry<ModuleId, bool> entry in original.entries) {
          await appModel.setModuleEnabled(entry.key, entry.value);
        }
        await tester.pump(const Duration(seconds: 1));
      }
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
