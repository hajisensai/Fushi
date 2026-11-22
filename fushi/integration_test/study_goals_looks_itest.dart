// 学习目标第三轮：在 MD3 / Apple（玻璃设计）/ 液态玻璃 / 墨水屏 / 深色几种外观下
// 抓真像素看设置 › 目标、目标面板、「今日」格（翻页、柱条、大小格）、「语言目标」格
// （一行 / 两行、分区卡 / 色块、一条一环）、阅读统计环、撤销提示条。
//
// 跑法（在 fushi/ 下，离屏、不抢焦点）：
//   dart tool/heavy.dart -- powershell -ExecutionPolicy Bypass -File //     tool/run_windows_itest.ps1 integration_test/study_goals_looks_itest.dart
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
import 'package:fushi/src/pages/implementations/home_widget_grid.dart'
    show homeWidgetEditRequested;
import 'package:fushi/src/pages/implementations/reading_statistics_page.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_study_goals.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiCard;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[goals-looks]';

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

/// 第三轮的目标组合：日语两条每日 + 一条每周（「语言目标」格一条一环）、中文每周期
/// 至多一条（日 / 周 / 月三环）、全部语言每周时长、每日复习（挖词目标 = Anki 时首页
/// 不出现，设置行写明原因）。
List<StudyGoal> _seedGoals() => <StudyGoal>[
  StudyGoal(
    id: 'g-ja-daily',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.daily,
    target: 10000,
    language: 'ja',
  ),
  StudyGoal(
    id: 'g-ja-watch',
    metric: StudyGoalId.watching,
    period: StudyGoalPeriod.daily,
    target: 30,
    language: 'ja',
  ),
  StudyGoal(
    id: 'g-ja-weekly',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.weekly,
    target: 60000,
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
    id: 'g-zh-weekly-watch',
    metric: StudyGoalId.watching,
    period: StudyGoalPeriod.weekly,
    target: 180,
    language: 'zh',
  ),
  StudyGoal(
    id: 'g-all-weekly-time',
    metric: StudyGoalId.total,
    period: StudyGoalPeriod.weekly,
    target: 600,
  ),
  StudyGoal(
    id: 'g-reviews',
    metric: StudyGoalId.reviews,
    period: StudyGoalPeriod.daily,
    target: 150,
  ),
];

/// 第五轮：各种完成状态——日语每日字数超出（3.7K / 2K）、中文每日字数刚好完成
/// （900 / 900）、日语观看进行中、全部语言每日听力今天是休息日、制卡没开始，外加
/// 每周 / 每月目标。
List<StudyGoal> _round5Goals() => <StudyGoal>[
  StudyGoal(
    id: 'r5-ja-chars',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.daily,
    target: 2000,
    language: 'ja',
  ),
  StudyGoal(
    id: 'r5-ja-watch',
    metric: StudyGoalId.watching,
    period: StudyGoalPeriod.daily,
    target: 30,
    language: 'ja',
  ),
  StudyGoal(
    id: 'r5-ja-weekly',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.weekly,
    target: 60000,
    language: 'ja',
  ),
  StudyGoal(
    id: 'r5-zh-chars',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.daily,
    target: 900,
    language: 'zh',
  ),
  StudyGoal(
    id: 'r5-zh-watch',
    metric: StudyGoalId.watching,
    period: StudyGoalPeriod.weekly,
    target: 180,
    language: 'zh',
  ),
  StudyGoal(
    id: 'r5-all-monthly',
    metric: StudyGoalId.total,
    period: StudyGoalPeriod.monthly,
    target: 1800,
  ),
  StudyGoal(
    id: 'r5-all-listen-rest',
    metric: StudyGoalId.listening,
    period: StudyGoalPeriod.daily,
    target: 30,
    activeWeekdays: <int>{DateTime.now().weekday % 7 + 1},
  ),
  StudyGoal(
    id: 'r5-mined',
    metric: StudyGoalId.mined,
    period: StudyGoalPeriod.daily,
    target: 10,
  ),
];

/// A：大「今日」+ 两块两行高的语言目标格 + 一块一行高的（全部语言）。
HomeWidgetLayout _layoutA() {
  const List<HomeWidgetItem> items = <HomeWidgetItem>[
    HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(3, 2)),
    HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(2, 2),
      language: 'ja',
    ),
    HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(2, 2),
      language: 'zh',
    ),
    HomeWidgetItem(HomeWidgetKind.languageGoals, HomeWidgetSize(2, 1)),
  ];
  return const HomeWidgetLayout(compact: items, wide: items);
}

/// C：用户挑了目标的格子——两行高混语言（标题「目标」）+ 一行高挑了两条（可滑）。
HomeWidgetLayout _layoutC() {
  const List<HomeWidgetItem> items = <HomeWidgetItem>[
    HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(3, 2),
      language: 'ja',
      goals: <String>['g-zh-daily', 'g-ja-watch', 'g-all-weekly-time'],
    ),
    HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(2, 1),
      language: 'zh',
      goals: <String>['g-zh-weekly-watch', 'g-zh-daily'],
    ),
    HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(2, 2),
      language: 'ko',
      goals: <String>['g-ja-weekly', 'g-ja-daily'],
    ),
  ];
  return const HomeWidgetLayout(compact: items, wide: items);
}

/// B：小「今日」（2×1、1×1）+ 一行高的日语格。
HomeWidgetLayout _layoutB(HomeWidgetSize today) {
  final List<HomeWidgetItem> items = <HomeWidgetItem>[
    HomeWidgetItem(HomeWidgetKind.today, today),
    const HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(2, 1),
      language: 'ja',
    ),
    const HomeWidgetItem(
      HomeWidgetKind.languageGoals,
      HomeWidgetSize(1, 1),
      language: 'zh',
    ),
  ];
  return HomeWidgetLayout(compact: items, wide: items);
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

/// 一种外观：设计系统 + 玻璃材质 + 明暗 + 墨水屏。
class _Look {
  const _Look(
    this.name, {
    this.design = 'material',
    this.glass = FushiGlassMaterial.off,
    this.brightness = 'light',
    this.eink = false,
  });

  final String name;
  final String design;
  final FushiGlassMaterial glass;
  final String brightness;
  final bool eink;
}

const List<_Look> _looks = <_Look>[
  _Look('material'),
  _Look('apple', design: 'glass'),
  _Look('glass', design: 'glass', glass: FushiGlassMaterial.liquid),
  _Look('eink', eink: true),
  _Look('dark', brightness: 'dark'),
];

/// 只跑这几种外观（逗号分隔，缺省全部）：Android 模拟器上只看 `material`。
const String _onlyLooks = String.fromEnvironment('GOALS_LOOKS');

/// 结束时不复原外观、留下目标与「周从周日开始」（Android 上接着看主屏幕小组件）。
const bool _keepForWidgets = bool.fromEnvironment('GOALS_KEEP');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('学习目标第三轮：各外观下的目标界面', (WidgetTester tester) async {
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

      _log('fresh goals: ${appModel.studyGoals}');
      await _seedFacts(appModel);
      // 新装（没编辑过目标）= 没有目标，「今日」格经典外观（字数 +「设定目标」）。
      await appModel.setHomeWidgetLayout(_layoutB(const HomeWidgetSize(2, 1)));
      await appModel.setShellContentLayout(ShellContentLayout.grid);
      HomePage.debugSelectTab?.call(HomeTab.settings);
      await _settle(tester);
      HomePage.debugSelectTab?.call(HomeTab.home);
      await _settle(tester, 30);
      await _shot(tester, '00-fresh-no-goal');
      _log(
        'fresh today texts: '
        '${_texts(find.byKey(const ValueKey<String>('home-study-card')))}',
      );

      await appModel.setSrsMiningTarget(SrsMiningTarget.anki);
      await appModel.setStudyGoals(_seedGoals());
      await appModel.setHomeTodaySwipeGoals(StudyGoalSwipeScope.all);
      _log('reviews hidden: ${appModel.studyGoalReviewsHidden}');

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
          try {
            d.onPressed?.call();
          } on NoSuchMethodError {
            d.onSelected?.call(true);
          }
        }
        await _settle(tester, 12);
      }

      final Set<String> only = <String>{
        for (final String n in _onlyLooks.split(','))
          if (n.trim().isNotEmpty) n.trim(),
      };
      for (final _Look look in _looks.where(
        (_Look l) => only.isEmpty || only.contains(l.name),
      )) {
        final String p = look.name;
        await _step('$p-apply', () async {
          await appModel.themeNotifier.setDesignSystem(look.design);
          await appModel.setGlassMaterial(look.glass);
          await appModel.setBrightnessMode(look.brightness);
          await appModel.setEinkMode(look.eink);
          await appModel.setHomeWidgetLayout(_layoutA());
          await appModel.setShellContentLayout(ShellContentLayout.grid);
          HomePage.debugSelectTab?.call(HomeTab.home);
          await _settle(tester, 30);
        });

        await _step('$p-home', () async {
          await _shot(tester, '$p-01-home-card');
          for (final String lang in <String>['ja', 'zh', 'all']) {
            final Finder card = find.byKey(
              ValueKey<String>('home-language-goals-card/$lang'),
            );
            _log('$p language-goals/$lang texts: ${_texts(card)}');
          }
          final Finder pager = find.descendant(
            of: find.byKey(const ValueKey<String>('home-today-goal-pager')),
            matching: find.byType(PageView),
          );
          if (pager.evaluate().isNotEmpty) {
            tester.widget<PageView>(pager).controller!.jumpToPage(2);
            await _settle(tester);
            await _shot(tester, '$p-02-home-pager-page2');
            tester.widget<PageView>(pager).controller!.jumpToPage(0);
            await _settle(tester);
          }
          await appModel.setShellContentLayout(ShellContentLayout.collage);
          await _settle(tester, 20);
          await _shot(tester, '$p-03-home-poster');
          await appModel.setHomeWidgetLayout(
            _layoutB(const HomeWidgetSize(2, 1)),
          );
          await _settle(tester, 20);
          await _shot(tester, '$p-04-home-poster-small');
          await appModel.setShellContentLayout(ShellContentLayout.grid);
          await _settle(tester, 20);
          await _shot(tester, '$p-05-home-card-small');
          await appModel.setHomeWidgetLayout(
            _layoutB(const HomeWidgetSize(1, 1)),
          );
          await _settle(tester, 20);
          await _shot(tester, '$p-06-home-card-1x1');
          await appModel.setHomeWidgetLayout(_layoutC());
          await _settle(tester, 20);
          await _shot(tester, '$p-13-home-picked-card');
          for (final String lang in <String>['ja', 'zh', 'ko']) {
            final Finder card = find.byKey(
              ValueKey<String>('home-language-goals-card/$lang'),
            );
            _log('$p picked/$lang texts: ${_texts(card)}');
          }
          final Finder picked = find.descendant(
            of: find.byKey(
              const ValueKey<String>('home-language-goals-pager/zh'),
            ),
            matching: find.byType(PageView),
          );
          _log('$p picked pager: ${picked.evaluate().length}');
          if (picked.evaluate().isNotEmpty) {
            tester.widget<PageView>(picked).controller!.jumpToPage(1);
            await _settle(tester);
            await _shot(tester, '$p-14-home-picked-pager-page2');
          }
          await appModel.setShellContentLayout(ShellContentLayout.collage);
          await _settle(tester, 20);
          await _shot(tester, '$p-15-home-picked-poster');
          await appModel.setShellContentLayout(ShellContentLayout.grid);
          await appModel.setHomeWidgetLayout(_layoutA());
          await _settle(tester, 20);
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
          await _shot(tester, '$p-07-settings-goals');
          _log('$p settings texts: ${_texts(find.byType(SettingsDetailPage))}');
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
          await _shot(tester, '$p-08-settings-goals-bottom');
          scroller.position.jumpTo(0);
          await _settle(tester);

          // 编辑复习目标：面板里写明它在首页不出现的原因。
          await tapKey('study-goal-row-g-reviews');
          await _shot(tester, '$p-09-sheet-reviews');
          _log(
            '$p sheet reviews note: '
            '${find.byKey(const ValueKey<String>('study-goal-reviews-hidden')).evaluate().length}',
          );
          nav.pop();
          await _settle(tester);
          // 中文目标：语言片只有「中文」，下面一排简繁选项。
          await tapKey('study-goal-row-g-zh-daily');
          await _shot(tester, '$p-16-sheet-zh-script');
          _log(
            '$p sheet zh script row: '
            '${find.byKey(const ValueKey<String>('study-goal-script')).evaluate().length}',
          );
          nav.pop();
          await _settle(tester);
          // 编辑日语字数目标（字数 chip、语言 chip、预设）。
          await tapKey('study-goal-row-g-ja-daily');
          await _shot(tester, '$p-10-sheet-edit');
          // 删除 → 撤销提示条。
          await tapKey('study-goal-delete');
          await _settle(tester, 4);
          await _shot(tester, '$p-11-undo-snackbar');
          _log(
            '$p after delete: goals=${appModel.studyGoals.length} '
            'snackbars=${find.byType(SnackBar, skipOffstage: false).evaluate().length} '
            'deletedText=${find.text(t.study_goal_deleted, skipOffstage: false).evaluate().length} '
            'undo=${find.byKey(const ValueKey<String>('study-goal-undo-delete'), skipOffstage: false).evaluate().length}',
          );
          final Finder undo = find.byKey(
            const ValueKey<String>('study-goal-undo-delete'),
          );
          if (undo.evaluate().isNotEmpty) {
            (tester.widget(undo) as dynamic).onPressed();
            await _settle(tester, 12);
          }
          _log('$p goals after undo: ${appModel.studyGoals.length}');
          // 撤销没生效时也把目标表复原，后面的外观照同一批目标截图。
          await appModel.setStudyGoals(_seedGoals());
          nav.pop();
          await _settle(tester);
        });

        // 用户截图的情形：旧数据里 zh-Hant 的听力目标 + 一行高的宽格子（旧写法、没有
        // scriptExact / lx 标记）→ 解析时归一成「中文」；一行格写「已完成 / 目标」+ 度量；
        // 挑了三条的宽一行格并排三条。普通态 + 编辑态各一张。
        await _step('$p-wide-1row', () async {
          final List<StudyGoal> keep = appModel.studyGoals;
          final List<StudyGoal> legacy = decodeStudyGoals(
            '[{"id":"g-zh-hant-listen","metric":"listening","period":"daily",'
            '"target":30,"language":"zh-Hant"}]',
          )!;
          await appModel.setStudyGoals(<StudyGoal>[...keep, ...legacy]);
          await appModel.setHomeWidgetLayout(
            decodeHomeWidgetLayout(
              '{"v":1,"compact":[{"k":"language_goals","c":2,"r":1,"l":"zh-Hant"},'
              '{"k":"language_goals","c":2,"r":1,"l":"ja",'
              '"goals":["g-ja-daily","g-ja-watch","g-ja-weekly"]}],'
              '"wide":[{"k":"language_goals","c":4,"r":1,"l":"zh-Hant"},'
              '{"k":"language_goals","c":6,"r":1,"l":"ja",'
              '"goals":["g-ja-daily","g-ja-watch","g-ja-weekly"]}]}',
            ),
          );
          await _settle(tester, 20);
          _log(
            '$p legacy zh goal language: ${appModel.studyGoals.last.language}',
          );
          _log(
            '$p wide-1row zh texts: '
            '${_texts(find.byKey(const ValueKey<String>('home-language-goals-card/zh')))}',
          );
          _log(
            '$p wide-1row ja texts: '
            '${_texts(find.byKey(const ValueKey<String>('home-language-goals-card/ja')))}',
          );
          await _shot(tester, '$p-17-wide-1row');
          // 进编辑态走设置页「编辑首页」同一个入口（不点坐标）。
          homeWidgetEditRequested.value = true;
          await _settle(tester, 20);
          await _shot(tester, '$p-18-wide-1row-edit');
          await tapKey('home-widget-edit-done');
          await appModel.setStudyGoals(keep);
          await appModel.setHomeWidgetLayout(_layoutA());
          await _settle(tester, 20);
        });

        await _step('$p-reading-stats', () async {
          unawaited(
            nav.push(
              MaterialPageRoute<void>(
                builder: (_) => const ReadingStatisticsPage(),
              ),
            ),
          );
          await _settle(tester, 30);
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
          if (ring.evaluate().isNotEmpty) {
            await Scrollable.ensureVisible(
              tester.element(ring),
              alignment: 0.4,
            );
            await _settle(tester, 8);
          }
          await _shot(tester, '$p-12-reading-stats-ring');
          nav.pop();
          await _settle(tester);
        });

        // 第五轮：完成状态（超出 / 完成 / 休息日 / 没开始）与「今日」格总览版式
        // （大 / 小格、分区卡 / 色块），聚焦版式同一批目标，设置行的状态环。
        await _step('$p-round5', () async {
          final List<StudyGoal> keep = appModel.studyGoals;
          await appModel.setSrsMiningTarget(SrsMiningTarget.srs);
          await appModel.setStudyGoals(_round5Goals());
          await appModel.setHomeTodayLayout(StudyGoalTodayLayout.overview);
          await appModel.setHomeWidgetLayout(_layoutA());
          await _settle(tester, 30);
          await _shot(tester, '$p-19-overview-card');
          _log(
            '$p overview texts: '
            '${_texts(find.byKey(const ValueKey<String>('home-study-card')))}',
          );
          await appModel.setShellContentLayout(ShellContentLayout.collage);
          await _settle(tester, 20);
          await _shot(tester, '$p-20-overview-poster');
          await appModel.setHomeWidgetLayout(
            _layoutB(const HomeWidgetSize(2, 1)),
          );
          await _settle(tester, 20);
          await _shot(tester, '$p-21-overview-poster-small');
          await appModel.setShellContentLayout(ShellContentLayout.grid);
          await _settle(tester, 20);
          await _shot(tester, '$p-22-overview-card-small');
          _log(
            '$p overview small texts: '
            '${_texts(find.byKey(const ValueKey<String>('home-study-card')))}',
          );
          await appModel.setHomeTodayLayout(StudyGoalTodayLayout.focus);
          await appModel.setHomeWidgetLayout(_layoutA());
          await _settle(tester, 20);
          await _shot(tester, '$p-23-focus-states');
          for (final String lang in <String>['ja', 'zh', 'all']) {
            _log(
              '$p states language-goals/$lang texts: '
              '${_texts(find.byKey(ValueKey<String>('home-language-goals-card/$lang')))}',
            );
          }
          await appModel.setShellContentLayout(ShellContentLayout.collage);
          await _settle(tester, 20);
          await _shot(tester, '$p-24-focus-states-poster');
          await appModel.setShellContentLayout(ShellContentLayout.grid);
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
          await _shot(tester, '$p-25-settings-states');
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
          await _shot(tester, '$p-26-settings-today-layout');
          nav.pop();
          await _settle(tester);
          await appModel.setSrsMiningTarget(SrsMiningTarget.anki);
          await appModel.setStudyGoals(keep);
          await _settle(tester, 10);
        });
      }

      if (_keepForWidgets) {
        // 小组件：周从周日开始（热力图的行起始日跟着变），目标留着。
        await appModel.setStatWeekStart(DateTime.sunday);
        await appModel.setHomeWidgetLayout(_layoutA());
        await _settle(tester, 40);
        _log('kept goals for widgets: ${appModel.studyGoals.length}');
        return;
      }
      // 复原外观（runner 每次是隔离库，复原只为保险）。
      await appModel.themeNotifier.setDesignSystem('auto');
      await appModel.setGlassMaterial(FushiGlassMaterial.off);
      await appModel.setBrightnessMode('system');
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
