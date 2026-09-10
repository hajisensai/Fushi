import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 阶段 2（统计中心大一统）结构守卫：
///  * 三域 tab 必须以 embedded 模式复用现有统计页（不嵌套 FushiPageScaffold，
///    避免双 Scaffold/双顶栏 + PageScrollRegistry 互踩）；
///  * 总览 tab 的目标分子必须走 studyGoalCharsForDay（BUG-1993 口径），时段明细
///    必须走统一 sheet（showStatPeriodDetailSheet）；
///  * 书架入口必须落阅读 tab（视频/游戏入口由
///    home_video_statistics_entry_static_test / game_statistics_page_guard_test
///    分别钉住）。
void main() {
  final String center = File(
    'lib/src/pages/implementations/statistics_center_page.dart',
  ).readAsStringSync();

  test('三域 tab 以 embedded 模式复用现有统计页', () {
    expect(center, contains('ReadingStatisticsPage(embedded: true)'));
    expect(center, contains('VideoStatisticsPage(embedded: true)'));
    expect(center, contains('GameStatisticsPage(embedded: true)'));
    expect(
      center,
      isNot(contains('FushiPageScaffold(embedded')),
      reason: '嵌入模式由各页自身分支处理，中心页不重复造壳',
    );
  });

  test('总览 tab：目标口径 + 统一时段明细 sheet', () {
    expect(center, contains('studyGoalCharsForDay('));
    expect(center, contains('showStatPeriodDetailSheet('));
  });

  test('总览时段卡带查词 / 制卡 / 收藏（与两个域 tab 的卡逐行同形）', () {
    for (final String label in <String>[
      't.stat_lookup',
      't.stat_mined',
      't.stat_favorited',
      't.stat_favorited_sentence',
    ]) {
      expect(
        center,
        contains(label),
        reason: '总览此前只有时长 / 字数，每天都在动的制卡与查词一个都看不到',
      );
    }
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

    test('四个 tab 的顶栏动作行逐颗同形：目标 → 刷新 → 清空全部统计', () {
      for (final String path in tabPages) {
        final String src = File(path).readAsStringSync();
        final int flag = src.indexOf('Icons.flag_outlined');
        final int refresh = src.indexOf('Icons.refresh');
        final int clear = src.indexOf('Icons.delete_sweep_outlined');
        expect(flag, isNonNegative, reason: '$path 缺目标按钮');
        expect(refresh, greaterThan(flag), reason: '$path 刷新不在目标之后');
        expect(clear, greaterThan(refresh), reason: '$path 清空不在刷新之后');
        for (final String key in <String>[
          't.stat_goal_set',
          't.stat_refresh',
          't.stat_clear_all',
        ]) {
          expect(src, contains(key), reason: '$path 缺 $key');
        }
      }
    });

    test('四个 tab 的时段卡副行同形：字数 + 查词 + 制卡 + 收藏 + 收藏语句', () {
      // 主值口径（时长）已由上游统一；副行此前四种形状——观看 / 游戏两个 tab 的卡
      // 连字数都没有。四张卡是横着比的，少一行就对不齐。
      for (final String path in tabPages) {
        final String src = File(path).readAsStringSync();
        expect(
          src,
          contains('formatStatChars('),
          reason: '$path 的时段卡缺字数副行',
        );
        for (final String key in <String>[
          't.stat_lookup',
          't.stat_mined',
          't.stat_favorited',
          't.stat_favorited_sentence',
        ]) {
          expect(src, contains(key), reason: '$path 的时段卡缺 $key 副行');
        }
        expect(
          src,
          contains('primaryValue: formatStatTime(ms)'),
          reason: '$path 的时段卡主值必须是时长（四张卡首行数字要可比）',
        );
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
