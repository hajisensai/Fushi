import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 三个域统计页同一骨架（用户 2026-09-08「统计全改成游戏那种」）的源码守卫：
///
///   时段卡 `_buildSummaryCards()` → 每日图 `buildStatDailyDurationChartSection(`
///   → 最近会话 `buildStatSessionSection(` → 按媒体列表（每行 `buildStatMediaRow(`）。
///
/// 阅读页额外在会话之后挂目标卡与「分析」折叠（`StatAnalysisFold(`），视频页把小时分布
/// 折进折叠区；三页的 `_buildContent` 里不许再有各自手搓的 tile / 进度条排行。
const Map<String, String> _pages = <String, String>{
  'reading': 'lib/src/pages/implementations/reading_statistics_page.dart',
  'video': 'lib/src/pages/implementations/video_statistics_page.dart',
  'game': 'lib/src/pages/implementations/game_statistics_page.dart',
};

void main() {
  for (final MapEntry<String, String> e in _pages.entries) {
    group(e.key, () {
      final String src = maskComments(
        File(e.value).readAsStringSync().replaceAll('\r\n', '\n'),
      );
      final String content = methodBody(src, 'Widget _buildContent()');

      test('骨架顺序：时段卡 → 每日图 → 最近会话 → 按媒体列表', () {
        final int cards = content.indexOf('_buildSummaryCards()');
        final int daily = content.indexOf('buildStatDailyDurationChartSection(');
        final int sessions = content.indexOf('buildStatSessionSection(');
        final int list = content.indexOf('SliverList(');
        expect(cards, isNonNegative);
        expect(daily, greaterThan(cards));
        expect(sessions, greaterThan(daily));
        expect(list, greaterThan(sessions));
      });

      test('按媒体一行走共享 buildStatMediaRow，不再手搓进度条排行', () {
        expect(containsIdentifier(src, 'buildStatMediaRow'), isTrue);
        expect(
          'LinearProgressIndicator('.allMatches(src).length,
          e.key == 'reading' ? 1 : 0,
          reason: '阅读页只剩目标卡的进度条；视频 / 游戏页零进度条',
        );
      });
    });
  }

  test('阅读页：目标卡在会话之后、「分析」折叠在按书列表之前；折叠里装齐五个下沉区块', () {
    final String src = maskComments(
      File(_pages['reading']!).readAsStringSync().replaceAll('\r\n', '\n'),
    );
    final String content = methodBody(src, 'Widget _buildContent()');
    final int sessions = content.indexOf('buildStatSessionSection(');
    final int goal = content.indexOf('_buildGoalPanel()');
    final int fold = content.indexOf('_buildAnalysisFold(');
    final int header = content.indexOf('_buildByBookHeader()');
    expect(goal, greaterThan(sessions));
    expect(fold, greaterThan(goal));
    expect(header, greaterThan(fold));
    final String foldBody = methodBody(src, 'Widget _buildAnalysisFold(bool wide)');
    for (final String block in <String>[
      '_buildKpiStrip()',
      '_buildTrendPanel()',
      '_buildMidSection(wide)',
      '_buildSourceBreakdown()',
      'buildStatHourlyFormatChartSection(context, _hourly)',
    ]) {
      expect(foldBody.contains(block), isTrue, reason: '$block 下沉进折叠区，不得删');
    }
  });

  test('视频页：小时分布折进「分析」', () {
    final String src = maskComments(
      File(_pages['video']!).readAsStringSync().replaceAll('\r\n', '\n'),
    );
    final String content = methodBody(src, 'Widget _buildContent()');
    final int fold = content.indexOf('StatAnalysisFold(');
    final int hourly = content.indexOf('buildStatHourlyChartSection(');
    expect(fold, isNonNegative);
    expect(hourly, greaterThan(fold));
  });
}
