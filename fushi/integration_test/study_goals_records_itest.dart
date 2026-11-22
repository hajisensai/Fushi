// 学习目标（记录列表，设计 A）真 app 走查：播种目标与带语言的学习事实，起真 app
// 抓真像素看——
//   1. 首页「今日」格：目标翻页每一页 + 右侧近 7 天柱条（应跟着当前目标走）、
//      小 / 大格、分区卡与色块两种外观；
//   2. 「语言目标」格（日本語 / 中文 / 没有目标的语言 = 空态）；
//   3. 设置 › 目标：列表、添加 / 编辑面板（各度量 / 周期 / 语言）、删除；
//   4. 在设置里改目标后回首页：「今日」格与「语言目标」格立刻跟着变；
//   5. 编辑首页：加「语言目标」格、改格子语言。
//
// 跑法（在 fushi/ 下，离屏、不抢焦点）：
//   dart tool/heavy.dart -- powershell -ExecutionPolicy Bypass -File \
//     tool/run_windows_itest.ps1 integration_test/study_goals_records_itest.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/home_widget_grid.dart';
import 'package:fushi/src/pages/implementations/reading_statistics_page.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_study_goals.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiCard;
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 截图名前缀（修前 / 修后两轮同一脚本）：`--dart-define=GOALS_PHASE=after`。
const String _phase = String.fromEnvironment(
  'GOALS_PHASE',
  defaultValue: 'before',
);

const String _tag = '[goals-probe]';

void _log(String message) => debugPrint('$_tag $message');

/// 近 14 天的学习：日语书（默认内容语言 = 日语）、中文视频（视频行标 zh）、日语视频。
Future<void> _seedFacts(AppModel appModel) async {
  final FushiDatabase db = appModel.database;
  await appModel.prefsRepo.setDefaultContentLanguage('ja');
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: 'goals-video-zh',
      title: '中文剧 测试',
      videoPath: 'C:/fixtures/zh.mp4',
      language: const Value<String>('zh'),
    ),
  );
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: 'goals-video-ja',
      title: 'アニメ テスト',
      videoPath: 'C:/fixtures/ja.mp4',
      language: const Value<String>('ja'),
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
    // 今天的段别跑到未来：截到现在之前。
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

  for (int d = 0; d < 14; d++) {
    // 日语书每天读（字数起伏），中文视频隔天看，日语视频每三天看。
    await segment(
      kActivityMediaBook,
      'goals-book-ja',
      '日本語の本',
      d,
      20 + (d * 7) % 30,
      3000 + (d * 1371) % 5000,
    );
    if (d.isEven) {
      await segment(
        kActivityMediaVideo,
        'goals-video-zh',
        '中文剧 测试',
        d,
        25 + (d * 5) % 20,
        900 + (d * 211) % 700,
      );
    }
    if (d % 3 == 0) {
      await segment(
        kActivityMediaVideo,
        'goals-video-ja',
        'アニメ テスト',
        d,
        24,
        700,
      );
    }
  }
}

/// brief 要求的目标组合：日语 / 中文每日字数、全部语言每周学习时长、日语每月字数、
/// 每日复习。
List<StudyGoal> _seedGoals() => <StudyGoal>[
  StudyGoal(
    id: 'g-ja-daily',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.daily,
    target: 10000,
    language: 'ja',
  ),
  StudyGoal(
    id: 'g-zh-daily',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.daily,
    target: 4000,
    language: 'zh',
  ),
  StudyGoal(
    id: 'g-all-weekly-time',
    metric: StudyGoalId.total,
    period: StudyGoalPeriod.weekly,
    target: 600,
  ),
  StudyGoal(
    id: 'g-ja-monthly',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.monthly,
    target: 250000,
    language: 'ja',
  ),
  StudyGoal(
    id: 'g-reviews',
    metric: StudyGoalId.reviews,
    period: StudyGoalPeriod.daily,
    target: 150,
  ),
  StudyGoal(
    id: 'g-zh-watch',
    metric: StudyGoalId.watching,
    period: StudyGoalPeriod.daily,
    target: 30,
    language: 'zh',
  ),
];

HomeWidgetLayout _layout({
  HomeWidgetSize today = const HomeWidgetSize(3, 2),
  List<HomeWidgetItem> extra = const <HomeWidgetItem>[],
}) {
  final List<HomeWidgetItem> items = <HomeWidgetItem>[
    HomeWidgetItem(HomeWidgetKind.today, today),
    const HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(1, 1),
      language: 'ja',
    ),
    const HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(2, 1),
      language: 'zh',
    ),
    ...extra,
  ];
  return HomeWidgetLayout(compact: items, wide: items);
}

/// 不 pumpAndSettle 的抓图（编辑态抖动 / 翻页动画会让 settle 一直等）。
Future<String> _shot(WidgetTester tester, String name) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  final String file = '$_phase-$name';
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
      final String path = '${observeScreenshotDir().path}/$file.png';
      await File(path).writeAsBytes(png.buffer.asUint8List(), flush: true);
      _log('shot $path');
      return path;
    } finally {
      image.dispose();
    }
  } catch (e) {
    _log('shot $file failed: $e');
    return '';
  }
}

/// [root] 下所有可见文字（Text / RichText），去重保序。
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

/// [root] 下所有 Semantics 标签（柱条 / 环的读屏文案）。
List<String> _semantics(Finder root) => <String>[
  for (final Element e
      in find.descendant(of: root, matching: find.byType(Semantics)).evaluate())
    if ((e.widget as Semantics).properties.label case final String l
        when l.isNotEmpty)
      l,
];

Future<void> _settle(WidgetTester tester, [int frames = 10]) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// 跑一步：失败只记日志不中断（走查要尽量多拿截图）。
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

  testWidgets('学习目标记录：首页 / 设置 / 面板 / 语言目标格走查', (WidgetTester tester) async {
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

      await _seedFacts(appModel);
      await appModel.setStudyGoals(_seedGoals());
      await appModel.setHomeTodaySwipeGoals(StudyGoalSwipeScope.all);
      await appModel.setHomeWidgetLayout(_layout());
      await appModel.setShellContentLayout(ShellContentLayout.grid);
      HomePage.debugSelectTab?.call(HomeTab.settings);
      await _settle(tester);
      HomePage.debugSelectTab?.call(HomeTab.home);
      await _settle(tester, 30);

      final Finder todayCard = find.byKey(
        const ValueKey<String>('home-study-card'),
      );
      final Finder pagerView = find.descendant(
        of: find.byKey(const ValueKey<String>('home-today-goal-pager')),
        matching: find.byType(PageView),
      );

      void dumpToday(String when) {
        _log('$when today texts: ${_texts(todayCard)}');
        _log(
          '$when today bars: ${_semantics(find.byKey(const ValueKey<String>('home-today-week')))}',
        );
        for (final String lang in <String>['ja', 'zh', 'ko']) {
          final Finder card = find.byKey(
            ValueKey<String>('home-language-goals-card/$lang'),
          );
          if (card.evaluate().isEmpty) continue;
          _log('$when language-goals/$lang texts: ${_texts(card)}');
          _log('$when language-goals/$lang sem: ${_semantics(card)}');
        }
      }

      Future<void> swipeTo(int page) async {
        if (pagerView.evaluate().isEmpty) {
          _log('no pager');
          return;
        }
        final PageView view = tester.widget<PageView>(pagerView);
        view.controller!.jumpToPage(page);
        await _settle(tester);
      }

      // 1. 首页，分区卡外观，「今日」3×2 + 两块语言目标格。
      await _step('home-card', () async {
        await _shot(tester, '01-home-card');
        dumpToday('home-card');
        for (int p = 0; p < 6; p++) {
          await swipeTo(p);
          await _shot(tester, '02-today-page-$p');
          dumpToday('page $p');
        }
        await swipeTo(0);
      });

      // 2. 色块外观。
      await _step('home-poster', () async {
        await appModel.setShellContentLayout(ShellContentLayout.collage);
        await _settle(tester, 20);
        await _shot(tester, '03-home-poster');
        dumpToday('poster');
        await swipeTo(2);
        await _shot(tester, '03b-home-poster-page2');
        dumpToday('poster page2');
        await swipeTo(0);
        await appModel.setShellContentLayout(ShellContentLayout.grid);
        await _settle(tester, 20);
      });

      // 3. 小格 / 中格。
      await _step('today-sizes', () async {
        for (final HomeWidgetSize size in const <HomeWidgetSize>[
          HomeWidgetSize(1, 1),
          HomeWidgetSize(2, 1),
          HomeWidgetSize(2, 2),
        ]) {
          await appModel.setHomeWidgetLayout(_layout(today: size));
          await _settle(tester, 20);
          await _shot(tester, '04-today-${size.cols}x${size.rows}');
          dumpToday('size ${size.cols}x${size.rows}');
        }
        await appModel.setHomeWidgetLayout(_layout());
        await _settle(tester, 20);
      });

      // 4. 设置 › 目标（从「设置」tab 进，像用户那样）。
      await _step('settings-goals', () async {
        HomePage.debugSelectTab?.call(HomeTab.settings);
        await _settle(tester);
        unawaited(
          nav.push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  const SettingsDetailPage.subPage(buildStudyGoalsDestination),
            ),
          ),
        );
        await _settle(tester, 20);
        await _shot(tester, '05-settings-goals');
        _log('settings texts: ${_texts(find.byType(SettingsDetailPage))}');
        final ScrollableState scroller = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(SettingsDetailPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        scroller.position.jumpTo(scroller.position.maxScrollExtent);
        await _settle(tester);
        await _shot(tester, '05b-settings-goals-bottom');
        scroller.position.jumpTo(0);
        await _settle(tester);
      });

      Future<void> tapKey(String key) async {
        final Finder f = find.byKey(ValueKey<String>(key));
        if (f.evaluate().isEmpty) {
          _log('missing $key');
          return;
        }
        final Widget w = tester.widget(f.first);
        final dynamic d = w;
        try {
          d.onTap?.call();
        } on NoSuchMethodError {
          try {
            d.onPressed?.call();
          } on NoSuchMethodError {
            d.onSelected?.call(true);
          }
        }
        await _settle(tester, 12);
      }

      // 5. 添加面板：各度量 / 周期。
      await _step('sheet-new', () async {
        await tapKey('study-goal-add');
        await _shot(tester, '06-sheet-new');
        for (final String m in <String>[
          'total',
          'reading',
          'listening',
          'watching',
          'reviews',
          'mined',
          'chars',
        ]) {
          final Finder chip = find.byKey(
            ValueKey<String>('study-goal-metric-$m'),
          );
          if (chip.evaluate().isEmpty) continue;
          (tester.widget(chip) as dynamic).onSelected(true);
          await _settle(tester, 6);
          await _shot(tester, '06-sheet-metric-$m');
        }
        for (final String lang in <String>['zh', 'ja']) {
          await tapKey('study-goal-language-$lang');
          await _shot(tester, '06-sheet-lang-$lang');
        }
        nav.pop();
        await _settle(tester);
      });

      // 6. 编辑：改中文每日字数目标的值并保存。
      await _step('sheet-edit', () async {
        await tapKey('study-goal-row-g-zh-daily');
        await _shot(tester, '07-sheet-edit');
        final Finder field = find.byKey(
          const ValueKey<String>('study-goal-target-field'),
        );
        final dynamic tf = tester.widget(field);
        (tf.controller as TextEditingController).text = '1500';
        await _settle(tester, 4);
        await tapKey('study-goal-save');
        await _shot(tester, '08-settings-after-edit');
        _log('after edit goals: ${appModel.studyGoals}');
      });

      // 7. 删除日语每月目标（看有没有撤销）。
      await _step('sheet-delete', () async {
        await tapKey('study-goal-row-g-ja-monthly');
        await tapKey('study-goal-delete');
        await _settle(tester, 4);
        await _shot(tester, '09-settings-after-delete');
        _log('after delete goals: ${appModel.studyGoals}');
        _log(
          'undo snackbar: '
          '${find.byKey(const ValueKey<String>('study-goal-undo-delete')).evaluate().length}',
        );
        // 撤销：放回原位。
        final Finder undo = find.byKey(
          const ValueKey<String>('study-goal-undo-delete'),
        );
        if (undo.evaluate().isNotEmpty) {
          (tester.widget(undo) as dynamic).onPressed();
          await _settle(tester, 12);
          await _shot(tester, '09b-settings-after-undo');
          _log('after undo goals: ${appModel.studyGoals}');
          // 再删一次，后面的步骤沿用「没有日语月目标」。
          await tapKey('study-goal-row-g-ja-monthly');
          await tapKey('study-goal-delete');
          await _settle(tester, 4);
        }
      });

      // 8. 回首页：改动应立刻反映（中文日目标 1,500，没有日语月目标）。
      await _step('home-after-settings', () async {
        nav.pop();
        await _settle(tester);
        HomePage.debugSelectTab?.call(HomeTab.home);
        await _settle(tester, 20);
        await _shot(tester, '10-home-after-settings');
        dumpToday('after-settings');
        final List<String> all = <String>[
          ..._texts(todayCard),
          ..._semantics(todayCard),
          ..._semantics(find.byType(HomeWidgetGrid)),
        ];
        _log(
          'after-settings mentions 1,500/1.5k: '
          '${all.any((String s) => s.contains('1,500') || s.contains('1.5k') || s.contains('1500'))}',
        );
      });

      // 9. 换主目标 / 滑动范围后回首页。
      await _step('main-goal-scope', () async {
        await appModel.setHomeTodayMainGoal('g-zh-watch');
        await appModel.setHomeTodaySwipeGoals(StudyGoalSwipeScope.daily);
        await _settle(tester, 20);
        await _shot(tester, '11-home-main-goal-zh-watch');
        dumpToday('main-goal');
      });

      // 10. 编辑首页：进编辑态、加「语言目标」格、改语言。
      await _step('edit-home', () async {
        homeWidgetEditRequested.value = true;
        await _settle(tester, 20);
        await _shot(tester, '12-edit-home');
        await tapKey('home-widget-edit-add');
        await _settle(tester, 12);
        await _shot(tester, '13-add-sheet');
        final Finder addTile = find.textContaining('Language goals');
        _log('add sheet has language goals: ${addTile.evaluate().length}');
        nav.pop();
        await _settle(tester);
        final HomeWidgetGrid grid = tester.widget<HomeWidgetGrid>(
          find.byType(HomeWidgetGrid),
        );
        final int index = grid.items.indexWhere(
          (HomeWidgetItem e) => e.kind == HomeWidgetKind.languageGoals,
        );
        grid.onConfigure?.call(index);
        await _settle(tester, 12);
        await _shot(tester, '14-configure-language');
        nav.pop();
        await _settle(tester);
        homeWidgetEditRequested.value = false;
        await _settle(tester, 12);
      });

      // 11. 没有目标的语言（韩语）= 空态。
      await _step('empty-state', () async {
        await appModel.setHomeWidgetLayout(
          _layout(
            extra: const <HomeWidgetItem>[
              HomeWidgetItem(
                HomeWidgetKind.languageGoals,
                HomeWidgetSize(1, 1),
                language: 'ko',
              ),
            ],
          ),
        );
        await _settle(tester, 20);
        await _shot(tester, '15-language-empty');
        dumpToday('empty');
      });

      // 12. 阅读统计页的目标环。
      await _step('reading-stats', () async {
        unawaited(
          nav.push(
            MaterialPageRoute<void>(
              builder: (_) => const ReadingStatisticsPage(),
            ),
          ),
        );
        await _settle(tester, 30);
        await _shot(tester, '16-reading-stats');
        // 「今天」环在「分析」折叠区里：先滚到折叠头（懒建的列表），展开、滚到环、
        // 点环开目标面板。
        final ScrollableState statsScroller = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ReadingStatisticsPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        for (
          int i = 0;
          i < 12 && find.text(t.stat_analysis).evaluate().isEmpty;
          i++
        ) {
          final ScrollPosition pos = statsScroller.position;
          pos.jumpTo((pos.pixels + 500).clamp(0.0, pos.maxScrollExtent));
          await _settle(tester, 4);
        }
        final Finder foldCard = find.ancestor(
          of: find.text(t.stat_analysis),
          matching: find.byType(FushiCard),
        );
        if (foldCard.evaluate().isNotEmpty) {
          (tester.widget(foldCard.first) as dynamic).onTap();
          await _settle(tester, 12);
        }
        final Finder ring = find.byKey(
          const ValueKey<String>('reading-stats-goal-ring'),
        );
        _log('reading stats ring: ${ring.evaluate().length}');
        if (ring.evaluate().isNotEmpty) {
          await Scrollable.ensureVisible(tester.element(ring), alignment: 0.4);
          await _settle(tester, 8);
          await _shot(tester, '16b-reading-stats-ring');
          await tapKey('reading-stats-goal-ring');
          await _settle(tester, 8);
          await _shot(tester, '16c-reading-stats-ring-sheet');
          _log(
            'ring opened sheet: '
            '${find.byKey(const ValueKey<String>('study-goal-save')).evaluate().length}',
          );
          nav.pop();
          await _settle(tester);
        }
        nav.pop();
        await _settle(tester);
      });

      _log('errors: ${errors.length}');
      for (final String e in errors.take(10)) {
        _log('error: $e');
      }
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
