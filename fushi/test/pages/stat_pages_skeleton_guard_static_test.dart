import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 三个域统计页与总览同一骨架（2026-10 统计中心重设计，`StatDashboardBody`）的
/// 源码守卫：
///
///   关键指标区 `StatHero(` → 趋势栏 `_buildRangeSection()`（范围条 → 范围时长图
///   → 所选范围卡 → 学习日历，2026-09-28 取代写死的近 30 天图）→ 明细栏：时段卡
///   `_buildSummaryCards()` → 最近会话 `buildStatSessionSection(` → 按媒体列表
///   （每行 `buildStatMediaRow(`）。
///
/// 阅读页的目标面板是指标区的 lead、「分析」折叠（`StatAnalysisFold(`）接在趋势栏
/// 末尾，视频页把小时分布折进折叠区；三页的 `_buildContent` 里不许再有各自手搓的
/// tile / 进度条排行。
const Map<String, String> _pages = <String, String>{
  'reading': 'lib/src/pages/implementations/reading_statistics_page.dart',
  'video': 'lib/src/pages/implementations/video_statistics_page.dart',
  'game': 'lib/src/pages/implementations/game_statistics_page.dart',
};

/// 从左括号 [open] 起按括号配对切出整个实参列表（注释已由 [maskComments] 掩掉；
/// 这些调用点的字符串字面量里没有括号）。
String _callArguments(String src, int open) {
  int depth = 0;
  for (int i = open; i < src.length; i++) {
    final String c = src[i];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return src.substring(open, i + 1);
    }
  }
  return src.substring(open);
}

void main() {
  for (final MapEntry<String, String> e in _pages.entries) {
    group(e.key, () {
      final String src = maskComments(
        File(e.value).readAsStringSync().replaceAll('\r\n', '\n'),
      );
      final String content = methodBody(src, 'Widget _buildContent()');

      test('骨架顺序：指标区 → 范围区块 → 时段卡 → 最近会话 → 按媒体列表', () {
        expect(content.contains('StatDashboardBody('), isTrue,
            reason: '${e.key} 不走共享骨架');
        final int hero = content.indexOf('StatHero(');
        final int range = content.indexOf('_buildRangeSection()');
        final int cards = content.indexOf('_buildSummaryCards()');
        final int sessions = content.indexOf('buildStatSessionSection(');
        final int list = content.indexOf('SliverList(');
        expect(hero, isNonNegative);
        expect(range, greaterThan(hero));
        expect(cards, greaterThan(range));
        expect(sessions, greaterThan(cards));
        expect(list, greaterThan(sessions));
        expect(content.contains('buildStatKpiTiles(context, computeStatKpis('),
            isTrue, reason: '${e.key} 的指标卡要走共享四卡');
      });

      test('范围区块齐全：范围条 / 学习日历 / 范围时长图 / 所选范围卡；不再写死近 30 天', () {
        final String range =
            methodBody(src, 'List<Widget> _buildRangeSection()');
        for (final String block in <String>[
          'StatRangeBar(',
          'buildStatRangeCalendarSection(',
          'buildStatRangeChartSection(',
          'buildStatRangeSummary(',
        ]) {
          expect(range.contains(block), isTrue, reason: '${e.key} 缺 $block');
        }
        expect(
          src.contains('lastDayKeys(30)'),
          isFalse,
          reason: '${e.key} 又写死了近 30 天窗口，图表必须跟随范围',
        );
      });

      test('按媒体一行走共享 buildStatMediaRow，不再手搓进度条排行', () {
        expect(containsIdentifier(src, 'buildStatMediaRow'), isTrue);
        expect(
          'LinearProgressIndicator('.allMatches(src).length,
          0,
          reason: '目标进度条在共享目标面板里；三个域页零进度条',
        );
      });
    });
  }

  test('阅读页：目标面板在指标区、「分析」折叠在趋势栏末尾；折叠里装齐五个下沉区块', () {
    final String src = maskComments(
      File(_pages['reading']!).readAsStringSync().replaceAll('\r\n', '\n'),
    );
    final String content = methodBody(src, 'Widget _buildContent()');
    final int goal = content.indexOf('StatGoalPanel(');
    final int range = content.indexOf('_buildRangeSection()');
    final int fold = content.indexOf('_buildAnalysisFold()');
    final int details = content.indexOf('details:');
    final int header = content.indexOf('_buildByBookHeader()');
    expect(goal, isNonNegative);
    expect(range, greaterThan(goal));
    expect(fold, greaterThan(range));
    expect(details, greaterThan(fold), reason: '折叠在趋势栏，不在明细栏');
    expect(header, greaterThan(details));
    final String foldBody = methodBody(src, 'Widget _buildAnalysisFold()');
    for (final String block in <String>[
      '_buildKpiStrip()',
      '_buildTrendPanel()',
      '_buildMidSection()',
      '_buildSourceBreakdown()',
      'buildStatHourlyFormatChartSection(context, _hourly)',
    ]) {
      expect(foldBody.contains(block), isTrue, reason: '$block 下沉进折叠区，不得删');
    }
  });

  /// BUG-2417：会话行的段 title 是**条目名**，合集里就是分集 / 分册名。会话流没有
  /// 时段明细 sheet 那种合集组头兜底，四个挂会话区块的页面（三个域 tab + 总览）
  /// 一个都不能漏传合集解析器，否则那一页的行又退回「暗中行动」认不出作品。
  test('四个页面的会话区块都传 collectionOf', () {
    const Map<String, String> pagesWithSessions = <String, String>{
      ..._pages,
      'center': 'lib/src/pages/implementations/statistics_center_page.dart',
    };
    for (final MapEntry<String, String> e in pagesWithSessions.entries) {
      final String src = maskComments(
        File(e.value).readAsStringSync().replaceAll('\r\n', '\n'),
      );
      for (final String call in <String>[
        'buildStatSessionSection(',
        'showStatSessionsSheet(',
      ]) {
        int at = src.indexOf(call);
        while (at >= 0) {
          expect(
            _callArguments(src, at + call.length - 1).contains('collectionOf:'),
            isTrue,
            reason: '${e.key} 的 $call 漏传合集解析器',
          );
          at = src.indexOf(call, at + call.length);
        }
      }
    }
  });

  /// 会话行封面（用户 2026-10-03「统计中心的会话也支持封面」）：总览三域混排，
  /// 单看标题认不出作品时封面是最快的辨认线索。四个挂会话区块的页面一个都不能
  /// 漏传封面解析器，否则那一页的会话行又只剩一颗小图标。
  test('四个页面的会话区块都传 coverOf', () {
    const Map<String, String> pagesWithSessions = <String, String>{
      ..._pages,
      'center': 'lib/src/pages/implementations/statistics_center_page.dart',
    };
    for (final MapEntry<String, String> e in pagesWithSessions.entries) {
      final String src = maskComments(
        File(e.value).readAsStringSync().replaceAll('\r\n', '\n'),
      );
      for (final String call in <String>[
        'buildStatSessionSection(',
        'showStatSessionsSheet(',
      ]) {
        int at = src.indexOf(call);
        while (at >= 0) {
          expect(
            _callArguments(src, at + call.length - 1).contains('coverOf:'),
            isTrue,
            reason: '${e.key} 的 $call 漏传封面解析器',
          );
          at = src.indexOf(call, at + call.length);
        }
      }
    }
  });

  test('视频页：小时分布折进「分析」', () {
    final String src = maskComments(
      File(_pages['video']!).readAsStringSync().replaceAll('\r\n', '\n'),
    );
    final String content = methodBody(src, 'Widget _buildContent()');
    final int fold = content.indexOf('StatAnalysisFold(');
    final int hourly = content.indexOf('buildStatHourlyChartSection(');
    final int details = content.indexOf('details:');
    expect(fold, isNonNegative);
    expect(hourly, greaterThan(fold));
    expect(details, greaterThan(hourly), reason: '折叠在趋势栏末尾');
  });
}
