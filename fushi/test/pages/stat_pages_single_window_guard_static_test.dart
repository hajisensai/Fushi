import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2219：统计页 / 首页在一轮加载里只许用**一个** `StatWindow`。
///
/// 此前聚合用加载时刻的窗口、时段卡谓词在点击时 `StatWindow(DateTime.now())` 现算
/// （首页反向：目标卡 build 时现取 todayKey、分子仍是旧聚合），跨午夜后「今日」卡有
/// 数、点开明细为空 / 首页目标环归零不再涨。修复：窗口存成字段（`_window` /
/// `_statWindow`），到下一个本地午夜排一次性 Timer 整页重聚合。
///
/// 守卫：四个页面文件里 `StatWindow(DateTime.now())` 只许出现在字段初值与加载入口
/// （`_loadFromDatabase` / `_load` / `_loadDashboardDataUnsafe`）里；`_buildSummaryCards`
/// 与目标卡不得现算，且必须挂 `_midnightReload`。
void main() {
  const Map<String, String> pages = <String, String>{
    'reading_statistics_page.dart': '_loadFromDatabase',
    'video_statistics_page.dart': '_loadFromDatabase',
    'game_statistics_page.dart': '_load',
  };

  for (final MapEntry<String, String> e in pages.entries) {
    test('${e.key}：时段卡谓词与聚合同一个窗口，跨午夜重聚合', () {
      final String src = File(
        'lib/src/pages/implementations/${e.key}',
      ).readAsStringSync();
      final int cards = src.indexOf('Widget _buildSummaryCards()');
      expect(cards, greaterThan(0), reason: '${e.key} 缺 _buildSummaryCards');
      final int cardsEnd = src.indexOf('\n  }\n', cards);
      final String cardsBody = src.substring(cards, cardsEnd);
      expect(
        cardsBody,
        isNot(contains('StatWindow(DateTime.now())')),
        reason: 'BUG-2219：时段卡谓词不得在点击时现算窗口',
      );
      expect(
        cardsBody,
        contains('final StatWindow w = _window;'),
        reason: 'BUG-2219：时段卡必须吃本轮加载时的 _window',
      );
      expect(
        src,
        contains('_midnightReload = Timer('),
        reason: 'BUG-2219：必须到下一个本地午夜整页重聚合',
      );
      expect(
        src,
        contains('StatWindow.untilNextStatDayBoundary('),
        reason: 'BUG-2219：午夜时长只从 StatWindow 取',
      );
      final RegExp anyNow = RegExp(r'StatWindow\(DateTime\.now\(\)\)');
      // 只许字段初值一处（`StatWindow _window = StatWindow(DateTime.now());`）。
      expect(
        anyNow.allMatches(src).length,
        1,
        reason: 'BUG-2219：${e.key} 里 StatWindow(DateTime.now()) 只许出现在字段初值',
      );
    });
  }

  test('home_dashboard_page.dart：目标卡 / 近 7 日日均吃 _statWindow，跨午夜重拉', () {
    final String src = File(
      'lib/src/pages/implementations/home_dashboard_page.dart',
    ).readAsStringSync();
    expect(src, contains('final String todayKey = _statWindow.todayKey;'));
    expect(src, contains('final StatWindow w = _statWindow;'));
    expect(src, contains('_midnightReload = Timer('));
    expect(
      RegExp(r'StatWindow\(DateTime\.now\(\)\)').allMatches(src).length,
      1,
      reason: 'BUG-2219：首页里 StatWindow(DateTime.now()) 只许出现在字段初值',
    );
  });
}
