// 统计中心「范围」验收（2026-09-28，对齐 Niratan 统计面板）：此前每个 tab 的图表
// 写死近 30 天。这里播 14 个月的跨域历史，起真 app 抓真像素看：
//   1. 默认「月」：范围条 / 学习日历 / 范围时长图（逐日）/ 所选范围卡；
//   2. 切「年」：图按周聚合、所选范围卡跟着变；
//   3. 切「全部」：图按月聚合，起点 = 最早有数据的那天；
//   4. 阅读 tab 的「书架对比」按范围求和、行首带封面槽；
//   5. 桌面端时段明细是居中对话框而不是底部抽屉。
//
// 跑法（在 fushi/ 下，离屏、不抢焦点）：
//   .\tool\run_windows_itest.ps1 integration_test/stats_range_itest.dart
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/pages/implementations/statistics_center_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 14 个月的历史：每隔几天一段书 / 视频，让「年」「全部」的图真的有柱可画。
Future<void> _seedHistory(AppModel appModel) async {
  final FushiDatabase db = appModel.database;
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
    final DateTime start = DateTime(now.year, now.month, now.day - daysAgo, 10);
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

  for (int d = 0; d < 420; d += 3) {
    final bool older = d > 120;
    await segment(
      kActivityMediaBook,
      older ? 'book-old' : 'book-new',
      older ? '新装版 タイム・リープ〈上〉' : '無職転生 〜異世界行ったら本気だす〜 22',
      d,
      20 + (d * 7) % 50,
      3000 + (d * 131) % 9000,
    );
    if (d % 2 == 0) {
      await segment(
        kActivityMediaVideo,
        'video-fixture',
        'Re:ゼロから始める異世界生活 S04',
        d,
        24,
        800,
      );
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '统计中心范围：月 / 年 / 全部 + 按书封面槽 + 桌面对话框',
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint(
          '[stats-range] FlutterError: ${details.exceptionAsString()}',
        );
      };
      try {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        await tester.pump(const Duration(seconds: 2));
        final AppModel appModel = await readyAppModel(tester);
        await _seedHistory(appModel);

        Future<void> settle([int frames = 12]) async {
          for (int f = 0; f < frames; f++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
        }

        Future<ObserveShot> shot(String name) async {
          final ObserveShot s = await captureFlutterFrame(tester, name);
          expect(s.saved, isTrue, reason: '$name 应落盘');
          expect(s.nonBlank, isTrue, reason: '$name 不应白屏');
          return s;
        }

        /// 直接调范围 chip 的回调（集成测试禁坐标点击；这里要证明的是渲染，
        /// 不是命中测试）。
        Future<void> selectMode(String label) async {
          final FushiSelectableChip chip = tester.widget<FushiSelectableChip>(
            find
                .byWidgetPredicate(
                  (Widget w) => w is FushiSelectableChip && w.label == label,
                )
                .first,
          );
          chip.onSelected!(true);
          await settle();
        }

        Future<void> scrollTo(Finder target) async {
          final ScrollableState scroller = tester.state<ScrollableState>(
            find
                .byWidgetPredicate(
                  (Widget w) =>
                      w is Scrollable && w.axisDirection == AxisDirection.down,
                )
                .last,
          );
          for (int step = 0; step < 60 && target.evaluate().isEmpty; step++) {
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
          await Scrollable.ensureVisible(
            tester.element(target.first),
            alignment: 0.05,
            duration: Duration.zero,
          );
          await settle(4);
        }

        final NavigatorState nav = appModel.navigatorKey.currentState!;
        nav.push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) =>
                const StatisticsCenterPage(initialTab: StatsCenterTab.overview),
          ),
        );
        await settle(20);

        // 1. 默认「月」。
        await scrollTo(find.text(t.stat_range_calendar));
        await shot('range-1-overview-month');
        expect(find.textContaining(t.stat_range_summary), findsWidgets);

        // 2. 「年」：图按周。
        await selectMode(t.stat_range_mode_year);
        await shot('range-2-overview-year');

        // 3. 「全部」：图按月，起点 = 最早一天。
        await selectMode(t.stat_all_time);
        await shot('range-3-overview-all');
        final String earliest = FushiDatabase.statDateKeyOf(
          DateTime.now().subtract(const Duration(days: 417)),
        );
        debugPrint('[stats-range] 期望「全部」起点附近 $earliest');
        await scrollTo(find.textContaining(t.stat_range_summary));
        await shot('range-4-overview-all-summary');

        nav.pop();
        await settle(4);

        // 4. 阅读 tab：书架对比按范围 + 封面槽（范围跨 tab 不共享：新开的中心页
        //    回到默认「月」，只剩近期那本书）。
        nav.push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) =>
                const StatisticsCenterPage(initialTab: StatsCenterTab.reading),
          ),
        );
        await settle(20);
        await selectMode(t.stat_all_time);
        await scrollTo(find.textContaining(t.stat_bookshelf_compare));
        await shot('range-5-reading-bookshelf-all');
        expect(find.text('新装版 タイム・リープ〈上〉'), findsOneWidget);
        await selectMode(t.stat_range_mode_month);
        await scrollTo(find.textContaining(t.stat_bookshelf_compare));
        await shot('range-6-reading-bookshelf-month');
        expect(
          find.text('新装版 タイム・リープ〈上〉'),
          findsNothing,
          reason: '本月没读过的书不进按月的书架对比',
        );

        // 5. 桌面时段明细 = 居中对话框。
        final StatFacts facts = await loadStatFacts(appModel.database);
        final BuildContext host = appModel.navigatorKey.currentContext!;
        if (!host.mounted) return;
        // ignore: unawaited_futures
        showStatPeriodDetailSheet(
          host,
          periodLabel: t.stat_this_month,
          contains: (String _) => true,
          facts: facts.dailyBooks,
          resolvers: StatPeriodDetailResolvers(
            titleOf: (StatFact f) => f.title,
          ),
        );
        await settle(8);
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        await shot('range-7-period-detail-dialog');
        nav.pop();
        await settle(4);
        nav.pop();
        await settle(4);
        debugPrint('[stats-range] 完成，启动期错误 ${errors.length} 条');
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
