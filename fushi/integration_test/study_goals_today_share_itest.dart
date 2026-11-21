// 周 / 月目标的「今日份额」（设计 A + B + C）：在 MD3 与墨水屏下抓真像素——
// 「今日」格聚焦页的双环 + 本周柱条（周中漏过一天 / 今天休息 / 本周已完成）、
// 小格与「语言目标」一行格的进度差、总览行、设置行的今日份额、编辑面板的生效日。
//
// 跑法（在 fushi/ 下，离屏、不抢焦点）：
//   dart tool/heavy.dart -- powershell -ExecutionPolicy Bypass -File
//     tool/run_windows_itest.ps1 integration_test/study_goals_today_share_itest.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_study_goals.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[goals-share]';

void _log(String message) => debugPrint('$_tag $message');

/// 本周的学习：日语书每天 3000 字，**昨天漏掉**（周中漏一天），今天 1200 字；中文视频
/// 每天 20 分钟（今天也看了 5 分钟）。
Future<void> _seedFacts(AppModel appModel) async {
  final FushiDatabase db = appModel.database;
  await appModel.prefsRepo.setDefaultContentLanguage('ja');
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: 'share-video-zh',
      title: '中文剧 测试',
      videoPath: 'C:/fixtures/zh.mp4',
      language: const Value<String>('zh'),
    ),
  );
  final String deviceId = await db.getOrCreateStudyDeviceId();
  final DateTime now = DateTime.now();
  Future<void> segment(
    String kind,
    String key,
    String title,
    int daysAgo,
    int minutes,
    int chars,
  ) async {
    final DateTime start = DateTime(now.year, now.month, now.day - daysAgo, 9);
    final DateTime begin = daysAgo == 0
        ? now.subtract(Duration(minutes: minutes + 1))
        : start;
    await db.upsertStudySegment(
      StudySegmentsCompanion.insert(
        uid: FushiDatabase.newStudySegmentUid(),
        deviceId: deviceId,
        mediaKind: kind,
        mediaKey: key,
        title: title,
        startAt: begin.millisecondsSinceEpoch,
        endAt: begin.add(Duration(minutes: minutes)).millisecondsSinceEpoch,
        dateKey: FushiDatabase.statDateKeyOf(begin),
        hour: begin.hour,
        durationMs: Value<int>(minutes * 60 * 1000),
        chars: Value<int>(chars),
        updatedAt: begin.millisecondsSinceEpoch,
      ),
    );
  }

  for (int d = 0; d < 7; d++) {
    if (d != 1) {
      await segment(
        kActivityMediaBook,
        'share-book-ja',
        '日本語の本',
        d,
        d == 0 ? 15 : 30,
        d == 0 ? 1200 : 3000,
      );
    }
    await segment(
      kActivityMediaVideo,
      'share-video-zh',
      '中文剧 测试',
      d,
      d == 0 ? 5 : 20,
      0,
    );
  }
}

/// 今天以外的生效日（周目标今天休息）。
Set<int> _notToday() => <int>{
  for (int d = 1; d <= 7; d++)
    if (d != DateTime.now().weekday) d,
};

List<StudyGoal> _goals() => <StudyGoal>[
  StudyGoal(
    id: 'w-ja',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.weekly,
    target: 30000,
    language: 'ja',
  ),
  StudyGoal(
    id: 'w-zh-rest',
    metric: StudyGoalId.watching,
    period: StudyGoalPeriod.weekly,
    target: 240,
    language: 'zh',
    activeWeekdays: _notToday(),
  ),
  StudyGoal(
    id: 'w-all-done',
    metric: StudyGoalId.total,
    period: StudyGoalPeriod.weekly,
    target: 30,
  ),
  StudyGoal(
    id: 'm-ja',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.monthly,
    target: 120000,
    language: 'ja',
  ),
  StudyGoal(
    id: 'd-ja',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.daily,
    target: 3000,
    language: 'ja',
  ),
];

/// 大「今日」（聚焦）+ 两行高的日语格 + 一行高的中文格。
HomeWidgetLayout _layoutBig() {
  const List<HomeWidgetItem> items = <HomeWidgetItem>[
    HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(3, 2)),
    HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(2, 2),
      language: 'ja',
    ),
    HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(2, 1),
      language: 'zh',
    ),
  ];
  return const HomeWidgetLayout(compact: items, wide: items);
}

/// 小「今日」（2×1）+ 一行高的日语格（挑了周 / 月目标）+ 一行高的全部语言格。
HomeWidgetLayout _layoutSmall() {
  const List<HomeWidgetItem> items = <HomeWidgetItem>[
    HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(2, 1)),
    HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(2, 1),
      language: 'ja',
      goals: <String>['w-ja', 'm-ja'],
    ),
    HomeWidgetItem(HomeWidgetKind.languageGoals, HomeWidgetSize(2, 1)),
  ];
  return const HomeWidgetLayout(compact: items, wide: items);
}

/// 总览版式的大「今日」格。
HomeWidgetLayout _layoutOverview() {
  const List<HomeWidgetItem> items = <HomeWidgetItem>[
    HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(3, 3)),
  ];
  return const HomeWidgetLayout(compact: items, wide: items);
}

Future<String> _shot(WidgetTester tester, String name) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
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
      final String path = '${observeScreenshotDir().path}/$name.png';
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('周 / 月目标的今日份额：双环、本周柱条、进度差（MD3 + 墨水屏）', (
    WidgetTester tester,
  ) async {
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
      _log('week start: ${StatWindow.weekStartDay}, today: ${DateTime.now()}');

      await _seedFacts(appModel);
      await appModel.setStudyGoals(_goals());
      await appModel.setHomeTodaySwipeGoals(StudyGoalSwipeScope.all);
      await appModel.setShellContentLayout(ShellContentLayout.grid);

      Future<void> tapKey(String key) async {
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

      void logCard(String label, String key) =>
          _log('$label texts: ${_texts(find.byKey(ValueKey<String>(key)))}');

      for (final bool eink in <bool>[false, true]) {
        final String p = eink ? 'eink' : 'material';
        await _step('$p-apply', () async {
          await appModel.themeNotifier.setDesignSystem('material');
          await appModel.setBrightnessMode('light');
          await appModel.setEinkMode(eink);
          await appModel.setHomeTodayLayout(StudyGoalTodayLayout.focus);
          await appModel.setHomeWidgetLayout(_layoutBig());
          HomePage.debugSelectTab?.call(HomeTab.settings);
          await _settle(tester);
          HomePage.debugSelectTab?.call(HomeTab.home);
          await _settle(tester, 30);
        });

        // A + B：周中漏过一天、今天休息、本周已完成。
        for (final (String id, String name) in <(String, String)>[
          ('w-ja', '01-focus-weekly-missed-day'),
          ('w-zh-rest', '02-focus-weekly-rest-day'),
          ('w-all-done', '03-focus-week-done'),
          ('m-ja', '04-focus-monthly'),
        ]) {
          await _step('$p-$name', () async {
            await appModel.setHomeTodayMainGoal(id);
            await _settle(tester, 20);
            await _shot(tester, '$p-$name');
            logCard('$p $name today', 'home-study-card');
          });
        }
        await _step('$p-language-tiles', () async {
          logCard('$p ja 2-row', 'home-language-goals-card/ja');
          logCard('$p zh 1-row', 'home-language-goals-card/zh');
        });

        // C：小「今日」格与一行高的「语言目标」格带进度差。
        await _step('$p-small', () async {
          await appModel.setHomeTodayMainGoal('w-ja');
          await appModel.setHomeWidgetLayout(_layoutSmall());
          await _settle(tester, 20);
          await _shot(tester, '$p-05-small-tiles-pace');
          logCard('$p small today', 'home-study-card');
          logCard('$p small ja', 'home-language-goals-card/ja');
          logCard('$p small all', 'home-language-goals-card/all');
        });

        await _step('$p-overview', () async {
          await appModel.setHomeTodayLayout(StudyGoalTodayLayout.overview);
          await appModel.setHomeWidgetLayout(_layoutOverview());
          await _settle(tester, 20);
          await _shot(tester, '$p-06-overview');
          logCard('$p overview', 'home-study-card');
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
          await _settle(tester, 20);
          await _shot(tester, '$p-07-settings-rows');
          // 编辑周目标：周 / 月目标也有「生效日」，提示换成「按这些日子摊」。
          await tapKey('study-goal-row-w-zh-rest');
          final Finder hint = find.byKey(
            const ValueKey<String>('study-goal-days-hint'),
          );
          if (hint.evaluate().isNotEmpty) {
            await Scrollable.ensureVisible(tester.element(hint));
            await _settle(tester);
          }
          await _shot(tester, '$p-08-sheet-weekly-active-days');
          _log(
            '$p sheet days: '
            '${find.byKey(const ValueKey<String>('study-goal-days')).evaluate().length}',
          );
          nav.pop();
          await _settle(tester);
          nav.pop();
          await _settle(tester);
        });
      }

      await appModel.setEinkMode(false);
      await appModel.themeNotifier.setDesignSystem('auto');
      await appModel.setBrightnessMode('system');
      _log('errors: ${errors.length}');
      for (final String e in errors.take(10)) {
        _log('error: $e');
      }
      expect(errors, isEmpty, reason: errors.take(3).join('\n'));
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
