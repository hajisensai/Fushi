import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi_core/fushi_core.dart';

/// 时段明细 sheet（阶段 1，统计中心大改造）的行为守卫：
///  * 时段谓词过滤：只聚合 contains(dateKey) 命中的行，跨日边界不吞相邻日；
///  * 来源分节（阅读/观看/游戏）+ 节内按合集分组（组头名在左 + 组小计），
///    组间按小计时长倒序、组内条目按时长倒序、未分组殿后；
///  * 同一媒体多行（时长段 + 字数段）按 identityKey 并组，不出两条；
///  * 空时段渲染空态文案；
///  * 条目点击回调收到 mediaKind/mediaKey，且 sheet 已收起。
StatFact _fact(
  String kind,
  String dateKey, {
  String key = '',
  String title = '',
  int chars = 0,
  int ms = 0,
}) => StatFact(
  mediaKind: kind,
  mediaKey: key,
  title: title,
  format: '',
  dateKey: dateKey,
  hour: -1,
  ms: ms,
  chars: chars,
  pages: 0,
  lastActiveMs: 0,
);

Future<void> _open(
  WidgetTester tester, {
  required List<StatFact> facts,
  required bool Function(String) contains,
  String? Function(StatFact)? collectionOf,
  Future<void> Function(String, String)? onEntryTap,
  Future<bool> Function(StatPeriodEntryTarget)? onEntryDelete,
  void Function(bool deleted)? onClosed,
}) async {
  late BuildContext hostContext;
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
  showStatPeriodDetailSheet(
    hostContext,
    periodLabel: 'PERIOD',
    contains: contains,
    facts: facts,
    resolvers: StatPeriodDetailResolvers(
      titleOf: (StatFact f) => f.title.isEmpty ? f.mediaKey : f.title,
      collectionOf: collectionOf,
      onEntryTap: onEntryTap,
      onEntryDelete: onEntryDelete,
    ),
  ).then((bool deleted) => onClosed?.call(deleted));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('时段谓词过滤 + 来源分节：命中日入节，相邻日不进', (WidgetTester tester) async {
    await _open(
      tester,
      facts: <StatFact>[
        _fact('book', '2026-09-01', key: 'b1', title: '小説', chars: 1000),
        _fact('video', '2026-09-01', key: 'v1', title: '动画EP1', ms: 60000),
        _fact('game', '2026-09-01', key: 'g1', title: 'Clannad', ms: 120000),
        _fact('book', '2026-08-31', key: 'b2', title: '昨日的书', chars: 999),
      ],
      contains: (String d) => d == '2026-09-01',
    );
    expect(find.text('小説'), findsOneWidget);
    expect(find.text('动画EP1'), findsOneWidget);
    expect(find.text('Clannad'), findsOneWidget);
    expect(find.text('昨日的书'), findsNothing);
    // 三个来源节头都在，且按 阅读→观看→游戏 排列。
    final double readY = tester.getTopLeft(find.text(t.home_filter_read)).dy;
    final double watchY = tester.getTopLeft(find.text(t.home_filter_watch)).dy;
    final double gameY = tester.getTopLeft(find.text(t.home_filter_game)).dy;
    expect(readY, lessThan(watchY));
    expect(watchY, lessThan(gameY));
  });

  testWidgets('BUG-2216：legacy 无身份行 unique-title 吸收进唯一身份组；同名双身份不合并', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      facts: <StatFact>[
        // 「已删又重导」的书：段带 bookKey，legacy 日行只有 title。
        _fact(
          kActivityMediaBook,
          '2026-06-06',
          key: 'k1',
          title: 'Solo',
          ms: 60000,
        ),
        _fact(kActivityMediaBook, '2026-06-05', title: 'Solo', ms: 30000),
        // 同名两本各有身份：两条，不合并。
        _fact(
          kActivityMediaBook,
          '2026-06-06',
          key: 'd1',
          title: 'Dup',
          ms: 1000,
        ),
        _fact(
          kActivityMediaBook,
          '2026-06-06',
          key: 'd2',
          title: 'Dup',
          ms: 2000,
        ),
        // 同名歧义的 legacy 行：不贴给任何一本，独立成无身份条目。
        _fact(kActivityMediaBook, '2026-06-06', title: 'Dup', ms: 3000),
      ],
      contains: (String _) => true,
    );
    expect(find.text('Solo'), findsOneWidget, reason: 'legacy 行并入唯一身份组');
    expect(find.text('Dup'), findsNWidgets(3), reason: '两个身份 + 一个无身份组');
  });

  testWidgets('BUG-2216：库表判同名歧义时，unique-title 也不许吸收', (
    WidgetTester tester,
  ) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                hostContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    showStatPeriodDetailSheet(
      hostContext,
      periodLabel: 'PERIOD',
      contains: (String _) => true,
      facts: <StatFact>[
        _fact(
          kActivityMediaBook,
          '2026-06-06',
          key: 'k1',
          title: 'A',
          ms: 60000,
        ),
        _fact(kActivityMediaBook, '2026-06-05', title: 'A', ms: 30000),
      ],
      resolvers: StatPeriodDetailResolvers(
        titleOf: (StatFact f) => f.title,
        ambiguousTitlesOf: (String kind) => <String>{'A'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('A'), findsNWidgets(2), reason: '行宇宙唯一但库表判同名 → 不吸收');
  });

  testWidgets('同一媒体的时长段与字数段按 identityKey 并组成一条', (WidgetTester tester) async {
    await _open(
      tester,
      facts: <StatFact>[
        _fact('game', '2026-09-01', key: 'g1', title: 'Clannad', ms: 60000),
        _fact('game', '2026-09-01', key: 'g1', title: 'Clannad', chars: 500),
      ],
      contains: (String _) => true,
    );
    expect(find.text('Clannad'), findsOneWidget);
  });

  testWidgets('合集分组：组头在左带小计、组间按时长倒序、未分组殿后', (WidgetTester tester) async {
    await _open(
      tester,
      facts: <StatFact>[
        _fact('video', '2026-09-01', key: 'v1', title: '小合集EP', ms: 60000),
        _fact('video', '2026-09-01', key: 'v2', title: '大合集EP1', ms: 120000),
        _fact('video', '2026-09-01', key: 'v3', title: '大合集EP2', ms: 180000),
        _fact('video', '2026-09-01', key: 'v4', title: '散片', ms: 999999),
      ],
      contains: (String _) => true,
      collectionOf: (StatFact f) => switch (f.mediaKey) {
        'v1' => '小合集',
        'v2' || 'v3' => '大合集',
        _ => null,
      },
    );
    // 大合集小计 300000ms > 小合集 60000ms → 大合集组在前；散片（未分组）虽然
    // 时长最大，仍殿后并挂「未分组」头。
    final double bigY = tester.getTopLeft(find.text('大合集')).dy;
    final double smallY = tester.getTopLeft(find.text('小合集')).dy;
    final double ungroupedY = tester
        .getTopLeft(find.text(t.stat_detail_ungrouped))
        .dy;
    final double looseY = tester.getTopLeft(find.text('散片')).dy;
    expect(bigY, lessThan(smallY));
    expect(smallY, lessThan(ungroupedY));
    expect(ungroupedY, lessThan(looseY));
    // 组内条目按时长倒序：EP2(180000) 在 EP1(120000) 之前。
    expect(
      tester.getTopLeft(find.text('大合集EP2')).dy,
      lessThan(tester.getTopLeft(find.text('大合集EP1')).dy),
    );
  });

  testWidgets('空时段渲染空态文案', (WidgetTester tester) async {
    await _open(
      tester,
      facts: <StatFact>[
        _fact('book', '2026-08-31', key: 'b1', title: '书', chars: 1),
      ],
      contains: (String d) => d == '2026-09-01',
    );
    expect(find.text(t.stat_detail_empty), findsOneWidget);
    expect(find.text('书'), findsNothing);
  });

  testWidgets('长按条目 → 确认删除 → 回调收到身份 + 命中日集，行移除、汇总重算、关闭时报告已删', (
    WidgetTester tester,
  ) async {
    StatPeriodEntryTarget? target;
    bool? closedDeleted;
    await _open(
      tester,
      facts: <StatFact>[
        _fact('video', '2026-09-01', key: 'v1', title: 'EP1', ms: 60000),
        _fact('video', '2026-09-02', key: 'v1', title: 'EP1', ms: 60000),
        _fact('video', '2026-09-03', key: 'v2', title: 'EP2', ms: 30000),
        _fact('video', '2026-08-20', key: 'v1', title: 'EP1', ms: 999999),
      ],
      contains: (String key) => key.startsWith('2026-09'),
      onEntryDelete: (StatPeriodEntryTarget t) async {
        target = t;
        return true;
      },
      onClosed: (bool deleted) => closedDeleted = deleted,
    );
    expect(find.text('EP1'), findsOneWidget);
    await tester.longPress(find.text('EP1'));
    await tester.pumpAndSettle();
    expect(find.text(t.stat_delete_title), findsOneWidget, reason: '先确认再删');
    await tester.tap(find.text(t.dialog_delete));
    await tester.pumpAndSettle();
    expect(target, isNotNull);
    expect(target!.mediaKind, kActivityMediaVideo);
    expect(target!.mediaKey, 'v1');
    expect(target!.title, 'EP1');
    expect(target!.dateKeys, <String>{
      '2026-09-01',
      '2026-09-02',
    }, reason: '只删本时段求和用到的那几天；08-20 不在时段内不动');
    expect(find.text('EP1'), findsNothing);
    expect(find.text('EP2'), findsOneWidget);
    // 关掉 sheet：调用方收到「删过」。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(closedDeleted, isTrue);
  });

  testWidgets('删除确认取消：不回调、行保留、关闭时报告未删', (WidgetTester tester) async {
    bool called = false;
    bool? closedDeleted;
    await _open(
      tester,
      facts: <StatFact>[
        _fact('book', '2026-09-01', key: 'b1', title: '书A', ms: 60000),
      ],
      contains: (String _) => true,
      onEntryDelete: (StatPeriodEntryTarget _) async {
        called = true;
        return true;
      },
      onClosed: (bool deleted) => closedDeleted = deleted,
    );
    await tester.longPress(find.text('书A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(called, isFalse);
    expect(find.text('书A'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(closedDeleted, isFalse);
  });

  testWidgets('条目点击：回调收到身份且 sheet 已收起', (WidgetTester tester) async {
    String? tappedKind;
    String? tappedKey;
    await _open(
      tester,
      facts: <StatFact>[
        _fact('video', '2026-09-01', key: 'v1', title: '动画EP1', ms: 60000),
      ],
      contains: (String _) => true,
      onEntryTap: (String kind, String key) async {
        tappedKind = kind;
        tappedKey = key;
      },
    );
    await tester.tap(find.text('动画EP1'));
    await tester.pumpAndSettle();
    expect(tappedKind, kActivityMediaVideo);
    expect(tappedKey, 'v1');
    expect(find.text('动画EP1'), findsNothing, reason: '跳转前 sheet 必须先收起');
  });
}
