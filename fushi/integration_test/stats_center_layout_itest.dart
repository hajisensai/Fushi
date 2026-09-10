// 统计中心四个 tab 的布局验收（用户 2026-09-10：「阅读的布局不统一修一下，做成
// 自适应统一布局」「所有界面都要统一」）。布局是纯排布，单测一条都不会红——只能
// 起真 app、播真数据、抓真像素来判。
//
// 跑法（在 fushi/ 下，离屏、不抢焦点）：
//   .\tool\run_windows_itest.ps1 integration_test/stats_center_layout_itest.dart
// 证据落 fushi/.codex-test/windows-itest/<runId>/screenshots/observe-*.png，
// 必须**真的打开看**：空白帧 = 启动失败，不是「跑过了」。
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/statistics_center_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// runner 每次都是干净隔离库，四个 tab 全是空态——空态下看不出任何布局问题。
/// 所以先播一批**跨三个域**的事实：段（时长 / 字数）+ 游玩骨架 + 四个计数面，
/// 让每个 tab 的时段卡、30 天柱面、会话流都真的有东西可画。
Future<void> _seedThreeDomains(AppModel appModel) async {
  final FushiDatabase db = appModel.database;
  final String deviceId = await db.getOrCreateStudyDeviceId();
  final DateTime now = DateTime.now();

  Future<void> segment({
    required String kind,
    required String key,
    required String title,
    required int daysAgo,
    required int hour,
    required int minutes,
    required int chars,
  }) async {
    final DateTime start = DateTime(
      now.year,
      now.month,
      now.day - daysAgo,
      hour,
    );
    await db.upsertStudySegment(
      StudySegmentsCompanion.insert(
        uid: FushiDatabase.newStudySegmentUid(),
        deviceId: deviceId,
        mediaKind: kind,
        mediaKey: key,
        title: title,
        startAt: start.millisecondsSinceEpoch,
        endAt: start.add(Duration(minutes: minutes)).millisecondsSinceEpoch,
        dateKey: FushiDatabase.statDateKeyOf(start),
        hour: start.hour,
        durationMs: Value(minutes * 60 * 1000),
        chars: Value(chars),
        updatedAt: start.millisecondsSinceEpoch,
      ),
    );
  }

  // 书：三天、每天两段（同一天两段相隔 > 30 分钟 → 两条会话，会话流才有多行）。
  for (int d = 0; d < 3; d++) {
    await segment(
      kind: kActivityMediaBook,
      key: 'book-fixture',
      title: '無職転生 〜異世界行ったら本気だす〜 21',
      daysAgo: d,
      hour: 10,
      minutes: 35 + d * 7,
      chars: 4200 + d * 900,
    );
    await segment(
      kind: kActivityMediaBook,
      key: 'book-fixture-2',
      title: '新装版 タイム・リープ〈上〉 あしたはきのう',
      daysAgo: d,
      hour: 20,
      minutes: 18 + d * 4,
      chars: 1600 + d * 300,
    );
  }
  // 视频。
  for (int d = 0; d < 3; d++) {
    await segment(
      kind: kActivityMediaVideo,
      key: 'video-fixture',
      title: 'Re:ゼロから始める異世界生活 4th season - S04E1${d + 4}',
      daysAgo: d,
      hour: 14,
      minutes: 23 + d * 5,
      chars: 900 + d * 220,
    );
  }

  // 游戏：库里一条条目 + 三条游玩骨架 + 对应的 hook 字数段。
  const String gameId = 'game-fixture';
  await appModel.galgameRepo.addAll(<GalgameEntry>[
    GalgameEntry(
      id: gameId,
      name: 'ATRI -My Dear Moments-',
      exePath: r'D:\fixture\atri\atri.exe',
      workdir: r'D:\fixture\atri',
      addedAt: now.subtract(const Duration(days: 30)),
    ),
  ]);
  for (int d = 0; d < 3; d++) {
    final DateTime start = DateTime(now.year, now.month, now.day - d, 21);
    final DateTime end = start.add(Duration(minutes: 40 + d * 11));
    await db.insertGalgameSession(
      GalgameSessionsCompanion.insert(
        gameId: gameId,
        startMs: start.millisecondsSinceEpoch,
        endMs: end.millisecondsSinceEpoch,
        durationSeconds: end.difference(start).inSeconds,
        dateKey: FushiDatabase.statDateKeyOf(end),
      ),
    );
    await segment(
      kind: kActivityMediaGame,
      key: gameId,
      title: 'ATRI -My Dear Moments-',
      daysAgo: d,
      hour: 21,
      minutes: 0,
      chars: 2800 + d * 640,
    );
  }

  // 四个计数面 × 三个来源：时段卡的后四行（查词 / 制卡 / 收藏 / 收藏语句）。
  // 游戏来源是本轮新加的（`lookup/overlay_stat_source.dart`），播它正是为了确认
  // 游戏 tab 的那四行真的画得出来，而不是恒 0。
  for (final (String source, int base) in <(String, int)>[
    (kStatSourceBook, 27),
    (kStatSourceVideo, 9),
    (kStatSourceGame, 15),
  ]) {
    for (int d = 0; d < 3; d++) {
      final DateTime day = DateTime(now.year, now.month, now.day - d);
      final String dateKey = FushiDatabase.statDateKeyOf(day);
      await db.addLookupCount(
        sourceType: source,
        dateKey: dateKey,
        delta: base + d * 4,
      );
      await db.addMiningCount(
        sourceType: source,
        dateKey: dateKey,
        delta: 2 + d,
      );
      await db.addFavoriteWord(
        expression: '$source-fav-$d',
        reading: 'よみ',
        glossary: '',
        sourceType: source,
        dateKey: dateKey,
      );
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('统计中心四个 tab：布局统一、指标齐平、会话可改可清', (WidgetTester tester) async {
    // 启动期 FlutterError（离线更新检查的 Socket 异常等）先收着，否则 pending error
    // 会撞上后面的 expect()。范式同 observe_offscreen_test。
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[stats-layout] FlutterError: ${details.exceptionAsString()}');
    };
    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));

      final AppModel appModel = await readyAppModel(tester);
      await _seedThreeDomains(appModel);

      const List<(StatsCenterTab, String)> tabs = <(StatsCenterTab, String)>[
        (StatsCenterTab.overview, 'overview'),
        (StatsCenterTab.reading, 'reading'),
        (StatsCenterTab.video, 'video'),
        (StatsCenterTab.game, 'game'),
      ];
      for (int i = 0; i < tabs.length; i++) {
        final (StatsCenterTab tab, String name) = tabs[i];
        // 每个 tab 单独 push 一次：TabBarView 无 keepAlive，直接指定 initialTab 比
        // 模拟横滑更确定，且四张图的滚动位置完全一致（能逐张对比左右留白）。
        final NavigatorState nav = appModel.navigatorKey.currentState!;
        unawaitedPush(nav, tab);
        for (int f = 0; f < 20; f++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        final ObserveShot shot = await captureFlutterFrame(
          tester,
          'stats-${i + 1}-$name',
        );
        expect(shot.saved, isTrue, reason: '$name tab 的帧应落盘');
        expect(
          shot.nonBlank,
          isTrue,
          reason: '$name tab 不应是白屏（${shot.path}, ${shot.bytes}B）',
        );
        // 四个 tab 的顶栏必须逐颗同形：目标 → 刷新 → 清空全部统计。
        for (final IconData icon in <IconData>[
          Icons.flag_outlined,
          Icons.refresh,
          Icons.delete_sweep_outlined,
        ]) {
          expect(
            find.byIcon(icon),
            findsWidgets,
            reason: '$name tab 缺顶栏按钮 ${icon.codePoint}',
          );
        }
        // 会话流每行都有铅笔，区块标题行有「清除全部会话」。
        final Finder clearAll = find.byKey(
          const ValueKey<String>('stat-sessions-clear-all'),
        );
        // 会话区在首屏之下，滚过去再抓一帧——会话行与「清除全部会话」就长在那儿，
        // 只抓首屏等于没看过它们。
        //
        // 🔴 **必须先滚再断言**：滚动容器只构建视口 + cacheExtent 内的 widget，
        // 会话区在视口外时 `find.byKey` 找到的是 0 个——那是「还没建」，不是
        // 「没有这个入口」。时段卡补上「字数」副行后每张卡长了一行，会话区正好
        // 被挤出缓存，同一条断言从绿变红（实测：加字数行之前找得到，之后找不到）。
        //
        // 滚动方式：直接推 [ScrollPosition]，不做坐标拖拽（集成测试禁坐标点击，
        // `docs/agent/integration-testing.md`），也不用带时长的
        // `Scrollable.ensureVisible`——它返回的是「动画结束才完成」的 future，在
        // testWidgets 的 async zone 里 await 会等不到自己驱动的帧，整条用例卡到
        // 超时（实测 8 分钟 timeout，不带滚动的同一条只要 59 秒）。
        final ScrollableState scroller = tester.state<ScrollableState>(
          find.byType(Scrollable).last,
        );
        for (int step = 0; step < 40 && clearAll.evaluate().isEmpty; step++) {
          final double next = scroller.position.pixels + 240;
          scroller.position.jumpTo(
            next > scroller.position.maxScrollExtent
                ? scroller.position.maxScrollExtent
                : next,
          );
          await tester.pump(const Duration(milliseconds: 60));
          if (scroller.position.pixels >= scroller.position.maxScrollExtent) {
            break;
          }
        }
        expect(clearAll, findsWidgets, reason: '$name tab 缺「清除全部会话」入口');
        await Scrollable.ensureVisible(
          tester.element(clearAll.first),
          alignment: 0.2,
          duration: Duration.zero,
        );
        for (int f = 0; f < 4; f++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        // 会话行整行可点 = 编辑入口（trailing 放不下第二颗按钮，见
        // stat_session_list.dart 文件头）。
        expect(
          find.byIcon(Icons.delete_outline),
          findsWidgets,
          reason: '$name tab 的会话行缺删除按钮',
        );
        final ObserveShot sessions = await captureFlutterFrame(
          tester,
          'stats-${i + 1}-$name-sessions',
        );
        expect(sessions.saved, isTrue, reason: '$name tab 会话区的帧应落盘');
        nav.pop();
        await tester.pump(const Duration(seconds: 1));
      }
      debugPrint('[stats-layout] 四个 tab 各抓一帧完成，启动期错误 ${errors.length} 条');
    } finally {
      FlutterError.onError = oldHandler;
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// 把统计中心推到全局 navigator 上（入口在首页 dashboard 的一颗卡上，焦点驱动
/// 在离屏下偶发点不中；这里走同一个页面构造函数，指定落在哪个 tab）。
void unawaitedPush(NavigatorState nav, StatsCenterTab tab) {
  nav.push(
    MaterialPageRoute<void>(
      builder: (BuildContext _) => StatisticsCenterPage(initialTab: tab),
    ),
  );
}
