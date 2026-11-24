// 学习目标第五轮（设置 › 目标）：用用户截图里那 9 条目标，在 MD3 / Apple / 墨水屏
// 下抓设置 › 目标（顶 / 底）、目标面板（新建 / 编辑中文目标），供改版前后对比。
//
// 跑法（在 fushi/ 下，离屏、不抢焦点）：
//   dart tool/heavy.dart -- powershell -ExecutionPolicy Bypass -File \
//     tool/run_windows_itest.ps1 integration_test/study_goals_settings_itest.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_study_goals.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[goals-settings]';

void _log(String message) => debugPrint('$_tag $message');

/// 用户截图里的 9 条目标（中文三条、日语三条、全部语言两条、制卡一条）。
List<StudyGoal> _userGoals() => <StudyGoal>[
  StudyGoal(
    id: 'g-zh-reading',
    metric: StudyGoalId.reading,
    period: StudyGoalPeriod.daily,
    target: 60,
    language: 'zh',
  ),
  StudyGoal(
    id: 'g-ja-reading',
    metric: StudyGoalId.reading,
    period: StudyGoalPeriod.daily,
    target: 60,
    language: 'ja',
  ),
  StudyGoal(
    id: 'g-all-watching',
    metric: StudyGoalId.watching,
    period: StudyGoalPeriod.daily,
    target: 120,
  ),
  StudyGoal(
    id: 'g-zh-total',
    metric: StudyGoalId.total,
    period: StudyGoalPeriod.daily,
    target: 30,
    language: 'zh',
  ),
  StudyGoal(
    id: 'g-ja-listening',
    metric: StudyGoalId.listening,
    period: StudyGoalPeriod.daily,
    target: 30,
    language: 'ja',
  ),
  StudyGoal(
    id: 'g-mined',
    metric: StudyGoalId.mined,
    period: StudyGoalPeriod.daily,
    target: 10,
  ),
  StudyGoal(
    id: 'g-zh-chars',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.weekly,
    target: 28000,
    language: 'zh',
  ),
  StudyGoal(
    id: 'g-ja-chars',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.weekly,
    target: 5000,
    language: 'ja',
  ),
  StudyGoal(
    id: 'g-all-chars',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.monthly,
    target: 4000,
  ),
];

class _Look {
  const _Look(
    this.name, {
    this.design = 'material',
    this.glass = FushiGlassMaterial.off,
    this.eink = false,
  });

  final String name;
  final String design;
  final FushiGlassMaterial glass;
  final bool eink;
}

const List<_Look> _looks = <_Look>[
  _Look('material'),
  _Look('apple', design: 'glass'),
  _Look('glass', design: 'glass', glass: FushiGlassMaterial.premium),
  _Look('eink', eink: true),
];

/// 截图文件名前缀（改版前跑 `before`，改版后跑 `after`）。
const String _phase = String.fromEnvironment(
  'GOALS_PHASE',
  defaultValue: 'after',
);

Future<void> _settle(WidgetTester tester, [int frames = 10]) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _step(String name, Future<void> Function() body) async {
  _log('── step $name');
  try {
    await body();
  } catch (e, st) {
    _log('step $name FAILED: $e\n$st');
  }
}

List<String> _texts(Finder root) {
  final List<String> out = <String>[];
  for (final Element e
      in find
          .descendant(of: root, matching: find.byType(RichText))
          .evaluate()) {
    final String s = (e.widget as RichText).text.toPlainText().trim();
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }
  return out;
}

Future<String> _shot(WidgetTester tester, String name) async {
  await _settle(tester, 8);
  try {
    final RenderView view = tester.binding.renderViews.first;
    // ignore: invalid_use_of_protected_member
    final OffsetLayer? layer = view.layer as OffsetLayer?;
    if (layer == null) return '';
    final ui.Image image = await layer.toImage(view.paintBounds);
    try {
      final ByteData? png = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (png == null) return '';
      final String path = '${observeScreenshotDir().path}/$_phase-$name.png';
      await File(path).writeAsBytes(png.buffer.asUint8List(), flush: true);
      _log('shot $path');
      return path;
    } finally {
      image.dispose();
    }
  } catch (e) {
    _log('shot $name failed: $e');
    return '';
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('学习目标第五轮：设置 › 目标与目标面板', (WidgetTester tester) async {
    final List<String> errors = <String>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details.exceptionAsString());
      _log('FlutterError: ${details.exceptionAsString()}');
    };
    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);
      final NavigatorState nav = appModel.navigatorKey.currentState!;
      await appModel.prefsRepo.setDefaultContentLanguage('ja');
      await appModel.setStudyGoals(_userGoals());
      HomePage.debugSelectTab?.call(HomeTab.settings);
      await _settle(tester);

      Future<void> press(String key) async {
        final Finder f = find.byKey(ValueKey<String>(key));
        if (f.evaluate().isEmpty) {
          _log('missing $key');
          return;
        }
        final dynamic d = tester.widget(f.first);
        try {
          d.onTap?.call();
        } on NoSuchMethodError {
          d.onPressed?.call();
        }
        await _settle(tester, 12);
      }

      for (final _Look look in _looks) {
        final String p = look.name;
        await _step('$p-apply', () async {
          await appModel.themeNotifier.setDesignSystem(look.design);
          await appModel.setGlassMaterial(look.glass);
          await appModel.setEinkMode(look.eink);
          await _settle(tester, 10);
        });
        await _step('$p-settings', () async {
          unawaited(
            nav.push(
              MaterialPageRoute<void>(
                builder: (_) => const SettingsDetailPage.subPage(
                  buildStudyGoalsDestination,
                ),
              ),
            ),
          );
          await _settle(tester, 24);
          await _shot(tester, '$p-01-settings-goals');
          _log('$p texts: ${_texts(find.byType(SettingsDetailPage))}');
          final ScrollableState scroller = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(SettingsDetailPage),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          scroller.position.jumpTo(scroller.position.maxScrollExtent / 2);
          await _settle(tester);
          await _shot(tester, '$p-02-settings-goals-mid');
          scroller.position.jumpTo(0);
          await _settle(tester);
          // 收起「日本語」组（改版后才有）。
          await press('study-goal-group-toggle-ja');
          await _shot(tester, '$p-03-settings-goals-collapsed');
          await press('study-goal-group-toggle-ja');
          await press('study-goal-row-g-zh-chars');
          await _shot(tester, '$p-04-sheet-edit-zh');
          nav.pop();
          await _settle(tester);
          await press('study-goal-add');
          await _shot(tester, '$p-05-sheet-new');
          nav.pop();
          await _settle(tester);
          nav.pop();
          await _settle(tester);
        });
      }
      await appModel.themeNotifier.setDesignSystem('auto');
      await appModel.setGlassMaterial(FushiGlassMaterial.off);
      await appModel.setEinkMode(false);
      _log('errors: ${errors.length}');
      for (final String e in errors.take(10)) {
        _log('error: $e');
      }
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
