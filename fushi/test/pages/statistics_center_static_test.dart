import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 阶段 2（统计中心大一统）结构守卫：
///  * 三域 tab 必须以 embedded 模式复用现有统计页（不嵌套 FushiPageScaffold，
///    避免双 Scaffold/双顶栏 + PageScrollRegistry 互踩）；
///  * 总览 tab 不再有目标卡 / 时段明细 / 媒体筛选（2026-10-09 统计中心精简），
///    计数挪进「所选范围」卡；
///  * 书架入口必须落阅读 tab（视频/游戏入口由
///    home_video_statistics_entry_static_test / game_statistics_page_guard_test
///    分别钉住）。
void main() {
  final String center = File(
    'lib/src/pages/implementations/statistics_center_page.dart',
  ).readAsStringSync();

  test('三域 tab 以 embedded 模式复用现有统计页', () {
    expect(
      center,
      matches(RegExp(
          r'ReadingStatisticsPage\(\s*embedded: true,\s*rangeSelection: _rangeSelection,')),
    );
    expect(
      center,
      matches(RegExp(
          r'VideoStatisticsPage\(\s*embedded: true,\s*rangeSelection: _rangeSelection,')),
    );
    expect(
      center,
      matches(RegExp(
          r'GameStatisticsPage\(\s*embedded: true,\s*rangeSelection: _rangeSelection,')),
    );
    expect(
      center,
      isNot(contains('FushiPageScaffold(embedded')),
      reason: '嵌入模式由各页自身分支处理，中心页不重复造壳',
    );
  });

  test('总览 tab：无媒体筛选 chip / 目标卡 / 时段明细（2026-10-09 精简）', () {
    for (final String gone in <String>[
      'StatMediaFilterBar(',
      'StatGoalPanel(',
      'buildStatPeriodSummaryGrid(',
    ]) {
      expect(center, isNot(contains(gone)), reason: '总览不再有 $gone');
    }
    // 查词 / 制卡 / 收藏词 / 收藏句仍在：挪进了「所选范围」卡。
    expect(center, contains('buildStatRangeCounterLines('));
  });

  test('总览的计数面与三个域 tab 同一次加载、同一份切分判据', () {
    // 跨域 = 不传 source；域 tab 各传自己那一个。四处都从 StatFacts.counters 取，
    // 谁也不再自己查 mining_statistics / lookup_mining_counters / favorite_words
    // ——否则总览的数字不再恒等于三个域 tab 之和，且没有任何测试能发现。
    expect(center, contains('includeCounters: true'));
    expect(center, contains('facts.counters'));
    for (final (String path, String source) in <(String, String)>[
      (
        'lib/src/pages/implementations/reading_statistics_page.dart',
        'StatSourceKind.book',
      ),
      (
        'lib/src/pages/implementations/video_statistics_page.dart',
        'StatSourceKind.video',
      ),
      (
        'lib/src/pages/implementations/game_statistics_page.dart',
        'StatSourceKind.game',
      ),
    ]) {
      final String src = File(path).readAsStringSync();
      expect(src, contains('includeCounters: true'), reason: path);
      expect(src, contains('facts.counters'), reason: path);
      expect(src, contains('lookupEvents(source: $source)'), reason: path);
      expect(src, contains('minedEvents(source: $source)'), reason: path);
      for (final String dao in <String>[
        'getMiningStatisticsBySource(',
        'getLookupMiningCountersBySource(',
        'getFavoriteWordsBySource(',
        'FavoriteSentenceRepository(',
      ]) {
        expect(src, isNot(contains(dao)), reason: '$path 不许再单独取计数面（$dao）');
      }
    }
  });

  test('三个统计页都支持 embedded 分支（buildEmbeddedStatTab）', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/reading_statistics_page.dart',
      'lib/src/pages/implementations/video_statistics_page.dart',
      'lib/src/pages/implementations/game_statistics_page.dart',
    ]) {
      final String source = File(path).readAsStringSync();
      expect(source, contains('buildEmbeddedStatTab('), reason: path);
    }
  });

  test('统计入口唯一落点在首页 dashboard（书架不再直连）', () {
    // 用户定案 2026-09-01：入口收敛。首页入口的正向断言在
    // home_video_statistics_entry_static_test，这里只钉书架侧不回潮。
    final String shelf = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();
    expect(shelf, isNot(contains('StatisticsCenterPage(')));
  });

  /// 用户 2026-09-10：「阅读的布局不统一修一下，做成自适应统一布局」「所有界面都
  /// 要统一」。四个 tab 横过去时不能有任何一个自带页面级宽度上限，也不能有哪一颗
  /// 顶栏按钮凭空多出来或凭空消失——这两件事都是纯排布，回潮时功能测试一条都不会红。
  group('四个 tab 统一', () {
    const List<String> tabPages = <String>[
      'lib/src/pages/implementations/statistics_center_page.dart',
      'lib/src/pages/implementations/reading_statistics_page.dart',
      'lib/src/pages/implementations/video_statistics_page.dart',
      'lib/src/pages/implementations/game_statistics_page.dart',
    ];

    test('没有任何一个 tab 自带页面级宽度上限', () {
      for (final String path in tabPages) {
        final String src = File(path).readAsStringSync();
        expect(
          src,
          isNot(contains('_kMaxContentWidth')),
          reason: '$path：阅读 tab 曾独有 Center + ConstrainedBox(1040)，'
              '横过去时只有它缩在中间一条',
        );
      }
    });

    test('四个 tab 只把「清空统计」交给页头的统计设置；没有目标 / 刷新按钮', () {
      for (final String path in tabPages) {
        final String src = File(path).readAsStringSync();
        expect(src, contains('StatTabSettings('), reason: path);
        expect(src, contains('trailing: StatRangeActions('),
            reason: '$path 的统计设置挂在范围条行尾');
        expect(src, contains('settings: _statSettings,'), reason: path);
        expect(src, contains('onClearAll: _confirmAndClearAll'), reason: path);
        for (final String gone in <String>[
          't.stat_goal_set',
          't.stat_refresh',
          'FushiIcons.flag,',
          'Icons.flag_outlined',
        ]) {
          expect(src, isNot(contains(gone)), reason: '$path 还留着 $gone');
        }
      }
    });

    test('四个 tab 的范围条都有「明细」入口：打开所选范围的时段明细 sheet', () {
      // 2026-10-09 删掉「时段明细」卡后补回的入口（齿轮旁，不是再加一张卡）。
      // 时段 = 范围条当前所选区间：谓词就是 StatRange.contains（周 = 自然周，
      // 与所选范围卡同口径），标题就是范围条上那行区间文字。
      for (final String path in tabPages) {
        final String src = File(path).readAsStringSync();
        expect(
          src,
          contains('onOpenDetail: () => unawaited(_showRangeDetail(range))'),
          reason: path,
        );
        final int start = src.indexOf(
          'Future<void> _showRangeDetail(StatRange range) async {',
        );
        expect(start, greaterThanOrEqualTo(0), reason: path);
        final String body = src.substring(start, src.indexOf('\n  }\n', start));
        expect(body, contains('showStatPeriodDetailSheet('), reason: path);
        expect(body, contains('periodLabel: formatStatRange(range)'),
            reason: path);
        expect(body, contains('contains: range.contains'), reason: path);
      }
    });

    test('四个 tab 同形：顶部学习日历（含过去一周）+ 所选范围卡带计数行，无时段卡', () {
      for (final String path in tabPages) {
        final String src = File(path).readAsStringSync();
        expect(src, contains('buildStatRangeCalendarSection('), reason: path);
        expect(src, contains('weekKeys:'), reason: path);
        expect(src, contains('buildStatRangeCounterLines('), reason: path);
        for (final String gone in <String>[
          '_buildSummaryCards',
          'buildStatPeriodSummaryGrid(',
          'buildStatKpiTiles(',
          't.stat_overview_periods',
        ]) {
          expect(src, isNot(contains(gone)), reason: '$path 还留着 $gone');
        }
      }
    });

    test('四个 tab 的会话区块都能改、能一次清光', () {
      for (final String path in tabPages) {
        final String src = File(path).readAsStringSync();
        expect(src, contains('onEdit:'), reason: '$path 会话区块漏传编辑回调');
        expect(src, contains('onClearAll:'), reason: '$path 会话区块漏传清除回调');
        expect(
          src,
          contains('applyStudySessionEdit('),
          reason: '$path 必须走会话编辑的唯一入口（先在 StudyClock 上退役 uid）',
        );
        expect(
          src,
          contains('deleteStudySessions('),
          reason: '$path 必须走批量删会话的唯一入口',
        );
        expect(
          src,
          isNot(contains('database.updateStudySession(')),
          reason: '$path 不许绕过 applyStudySessionEdit 直接调 DB 层',
        );
      }
    });
  });
}
