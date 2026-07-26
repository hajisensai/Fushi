import 'dart:async';

import 'package:drift/drift.dart' show QueryRow;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_detail_page.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import 'helpers/focus_driver.dart';
import 'test_helpers.dart';

/// 批次 11 真机（Windows 离屏 runner）验证：BUG-1095 台词浮窗字号设置项 + v56 迁移。
///
/// 只用焦点驱动（`FocusDriver` / 合成按键），绝不 `tester.tap` / 坐标点击。
/// 数据根由 `tool/run_windows_itest.ps1` 隔离（APPDATA/LOCALAPPDATA/TEMP/USERPROFILE
/// 全部重定向到 `.codex-test/windows-itest/<run-id>/isolated-root`），**不碰用户生产库**。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'batch11: 真 app 上 galgame 台词字号设置项焦点可达、写穿 DB、可还原；'
      '活库 schema=v56 且 galgames.launch_args 在场', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[batch11] FlutterError: ${details.exceptionAsString()}');
    };

    AppModel? appModel;
    String? originalFontPref;
    bool? originalFocusNav;
    try {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: 'Home 必须在 90s 内渲染');
      await tester.pump(const Duration(seconds: 2));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel model = container.read(appProvider);
      appModel = model;

      // ---------- ① 活库 schema 断言（v56 + launch_args） ----------
      final QueryRow version = await model.database
          .customSelect('PRAGMA user_version')
          .getSingle();
      final int userVersion = version.read<int>('user_version');
      debugPrint('[batch11] live DB user_version=$userVersion '
          'schemaVersion=${model.database.schemaVersion}');
      expect(userVersion, model.database.schemaVersion);
      expect(userVersion, 56, reason: 'v56 = galgames.launch_args');

      final List<QueryRow> cols = await model.database
          .customSelect('PRAGMA table_info(galgames)')
          .get();
      final Map<String, QueryRow> byName = <String, QueryRow>{
        for (final QueryRow r in cols) r.read<String>('name'): r,
      };
      debugPrint('[batch11] galgames columns=${byName.keys.toList()}');
      expect(byName.containsKey('launch_args'), isTrue,
          reason: '活库里 galgames 必须有 launch_args 列');
      expect(byName['launch_args']!.read<String>('type'), 'TEXT');
      expect(byName['launch_args']!.read<int>('notnull'), 1,
          reason: 'launch_args 非空');
      expect(byName['launch_args']!.read<String?>('dflt_value'), "''",
          reason: '默认空串 = 不带任何参数 = 旧启动命令行逐字节不变');

      // ---------- ② 向后兼容：全新库上的字号默认值 ----------
      await model.prefsRepo.refreshFromDb();
      originalFontPref =
          model.prefsRepo.prefsSnapshot['gal_hook_text_font_size'];
      debugPrint('[batch11] stored gal_hook_text_font_size='
          '${originalFontPref ?? "<unset>"} '
          'effective=${model.galHookTextFontSize}');
      if (originalFontPref == null) {
        // 全新隔离数据根：没有存过值 → 必须回落 30，正是旧公式
        // `30 * clamp(140dip/140dip, .9, 2.5)` = 30 的逐像素等价值。
        expect(model.galHookTextFontSize, 30.0,
            reason: '默认 30 == 旧公式在默认窗高 140dip 下的实际字号');
      }
      expect(PreferencesRepository.galHookTextFontSizeDefault, 30.0);
      expect(PreferencesRepository.galHookTextFontSizeMin, 12.0);
      expect(PreferencesRepository.galHookTextFontSizeMax, 72.0);

      // ---------- ③ 焦点驱动真设置项 ----------
      // Tab 在实验焦点导航关闭时被全局中和为 DoNothingIntent
      // （global_navigation.dart，TODO-112），先按 comprehensive_settings 同款
      // 范式打开它；放在字号断言之外，不混进本项的写穿差异。
      originalFocusNav = model.experimentalFocusNavigationEnabled;
      await model.setExperimentalFocusNavigationEnabled(true);
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // 折叠 section 里的行不入树 → 焦点到不了。测试钩子强制全展开（生产默认态
      // 由 collapsedByDefault 决定，与本条断言无关），finally 里还原。
      debugSettingsForceExpandAllSections = true;
      await _openLookupSettingsPage(tester);

      final String rowTitle = t.gal_hook_text_font_size;
      debugPrint('[batch11] looking for stepper row titled "$rowTitle"');

      final FocusDriver driver = FocusDriver(tester);
      final Finder rowFinder = find.ancestor(
        of: find.text(rowTitle),
        matching: find.byType(AdaptiveSettingsStepperRow),
      );
      final bool reached = await driver.focusWidget(rowFinder, maxSteps: 200);
      if (!reached) {
        // 打印本页所有 stepper 行标题，让「不可达」有可诊断的现场。
        final Iterable<AdaptiveSettingsStepperRow> steppers = find
            .byType(AdaptiveSettingsStepperRow)
            .evaluate()
            .map((Element e) => e.widget as AdaptiveSettingsStepperRow);
        debugPrint('[batch11] stepper rows currently built: '
            '${steppers.map((AdaptiveSettingsStepperRow r) => r.title).toList()}');
      }
      expect(reached, isTrue,
          reason: '「$rowTitle」必须能被 Tab 焦点驱动到（查词分类末尾，仅 Windows）');

      final double beforeValue = model.galHookTextFontSize;
      // Stepper 是单一焦点停靠点，左右方向键就地加减（不移动焦点）。
      await driver.adjust(steps: 3, up: LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 500));
      final double afterValue = model.galHookTextFontSize;
      debugPrint('[batch11] font size $beforeValue -> $afterValue '
          '(3 x arrowRight, step=1)');
      expect(afterValue, greaterThan(beforeValue),
          reason: '方向键必须真改到值（step=1，按 3 次）');
      expect(afterValue, beforeValue + 3.0,
          reason: 'step=1 且 3 次右键 → 恰好 +3（没有重复触发/丢事件）');

      // ---------- ④ 写穿 DB（真读回 preferences 表，不是只读内存） ----------
      final QueryRow? persisted = await model.database
          .customSelect(
            "SELECT value FROM preferences WHERE key = 'gal_hook_text_font_size'",
          )
          .getSingleOrNull();
      debugPrint('[batch11] preferences row value='
          '${persisted?.read<String>('value')}');
      expect(persisted, isNotNull, reason: '必须真写进 preferences 表');
      final String raw = persisted!.read<String>('value');
      expect(raw.startsWith('d:'), isTrue,
          reason: 'PrefCodec 把 double 编成 d:<value>，实得 $raw');
      expect(double.parse(raw.substring(2)), afterValue,
          reason: 'DB 里的值必须与内存值一致');

      // 绕过缓存重新从 DB 读，证明「读回也生效」。
      await model.prefsRepo.refreshFromDb();
      expect(model.galHookTextFontSize, afterValue,
          reason: 'refreshFromDb 后读回同一个值');

      // ---------- ⑤ 还原 ----------
      await driver.adjust(steps: 3, up: LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 500));
      await model.prefsRepo.refreshFromDb();
      debugPrint('[batch11] after restore=${model.galHookTextFontSize}');
      expect(model.galHookTextFontSize, beforeValue,
          reason: '左键 3 次必须回到原值（对称）');

      assertStrictErrors(errors);
      debugPrint('[batch11] PASS');
    } finally {
      debugSettingsForceExpandAllSections = false;
      // 兜底还原：把偏好恢复到测试前状态，绝不给用户留改动。
      final AppModel? model = appModel;
      if (model != null) {
        if (originalFontPref == null) {
          await model.database.deletePref('gal_hook_text_font_size');
        } else {
          await model.database
              .setPref('gal_hook_text_font_size', originalFontPref);
        }
        if (originalFocusNav != null) {
          await model.setExperimentalFocusNavigationEnabled(originalFocusNav);
        }
        await model.prefsRepo.refreshFromDb();
      }
      FlutterError.onError = oldHandler;
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// 推真「查词」设置分类详情页（与生产同一 schema、同一 shell）。
Future<void> _openLookupSettingsPage(WidgetTester tester) async {
  final NavigatorState nav = Navigator.of(
    tester.element(find.byType(Scaffold).first),
  );
  unawaited(nav.push(
    MaterialPageRoute<void>(
      builder: (BuildContext routeCtx) => Consumer(
        builder: (BuildContext ctx, WidgetRef ref, _) {
          final SettingsContext sctx = SettingsContext(
            context: ctx,
            appModel: ref.read(appProvider),
            ref: ref,
            readerSource: ReaderHibikiSource.instance,
            refresh: () {},
          );
          final SettingsDestination lookup = buildSettingsSchema(sctx)
              .firstWhere((SettingsDestination d) =>
                  d.id == SettingsDestinationId.lookup);
          return SettingsDetailPage(destination: lookup);
        },
      ),
    ),
  ));
  await tester.pump(const Duration(seconds: 2));
}
