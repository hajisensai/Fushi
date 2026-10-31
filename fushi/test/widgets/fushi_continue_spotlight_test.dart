import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';

/// 所有库页与首页共用的「继续」区（[FushiContinueSpotlight]，2026-10-31 合一）：
/// 主卡皮只看封面方向——横图剧照是叠层主卡，竖图（书 / 游戏 / 只有竖海报的
/// 视频）是封面 + 信息列主卡；其余条目是宽屏主卡旁 / 窄屏主卡下的封面行，
/// 必须能用鼠标横拖（用户实报「好像不能横向拖动」）。
void main() {
  final List<String> opened = <String>[];
  final List<String> menus = <String>[];

  FushiContinueEntry entry(int i, {bool still = true}) => FushiContinueEntry(
    key: ValueKey<String>('spot-$i'),
    focusId: FushiFocusId('spot-$i'),
    title: 'Work $i',
    eyebrow: 'Next · Episode ${i + 1} · 3 watched',
    subtitle: 'Next · Episode ${i + 1}',
    cover: ColoredBox(color: Color(0xFF203040 + i * 0x101010)),
    coverAspectRatio: still ? 16 / 9 : 2 / 3,
    progress: 0.5,
    onOpen: () => opened.add('$i'),
    onLongPress: () => menus.add('$i'),
  );

  Widget harness(
    double width,
    List<FushiContinueEntry> entries, {
    bool showSideWhenNarrow = true,
    bool staggerEntrance = true,
  }) => MaterialApp(
    theme: ThemeData(
      extensions: const <ThemeExtension<dynamic>>[FushiEinkTheme(false)],
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: FushiContinueSpotlight(
              main: entries.first,
              side: entries.sublist(1),
              showSideWhenNarrow: showSideWhenNarrow,
              staggerEntrance: staggerEntrance,
            ),
          ),
        ),
      ),
    ),
  );

  setUp(() {
    opened.clear();
    menus.clear();
  });

  Future<void> pumpAt(
    WidgetTester tester,
    double width,
    List<FushiContinueEntry> entries, {
    bool showSideWhenNarrow = true,
    bool staggerEntrance = true,
  }) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness(
        width,
        entries,
        showSideWhenNarrow: showSideWhenNarrow,
        staggerEntrance: staggerEntrance,
      ),
    );
    await tester.pumpAndSettle();
  }

  List<FushiContinueEntry> stills(int count) => <FushiContinueEntry>[
    for (int i = 0; i < count; i++) entry(i),
  ];

  ScrollPosition sidePosition(WidgetTester tester, Type scrollView) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(scrollView),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  testWidgets('宽屏剧照：主卡 16:9 与骨架同一套几何，旁边是两行横滑网格', (WidgetTester tester) async {
    await pumpAt(tester, 1200, stills(15));
    expect(tester.takeException(), isNull);

    final Size main = tester.getSize(
      find.byKey(const ValueKey<String>('spot-0')),
    );
    expect(main.width / main.height, closeTo(16 / 9, 0.01));
    expect(main, FushiContinueSpotlight.placeholderStillSize(1200));
    expect(find.byType(FushiContinueHero), findsNothing);

    final GridView grid = tester.widget<GridView>(find.byType(GridView));
    expect(grid.scrollDirection, Axis.horizontal);
    final Rect first = tester.getRect(
      find.byKey(const ValueKey<String>('spot-1')),
    );
    final Rect second = tester.getRect(
      find.byKey(const ValueKey<String>('spot-2')),
    );
    expect(first.left, greaterThan(main.width));
    expect(second.top, greaterThan(first.bottom));
    expect(first.width / first.height, closeTo(16 / 9, 0.01));
  });

  testWidgets('宽屏：封面网格能用鼠标横拖', (WidgetTester tester) async {
    await pumpAt(tester, 1200, stills(15));
    final ScrollPosition position = sidePosition(tester, GridView);
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.drag(
      find.byType(GridView),
      const Offset(-300, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('只有竖海报的作品：主卡走封面 + 信息列皮，不塞进 16:9', (WidgetTester tester) async {
    await pumpAt(tester, 1200, <FushiContinueEntry>[
      entry(0, still: false),
      entry(1),
      entry(2, still: false),
    ]);
    expect(tester.takeException(), isNull);
    expect(find.byType(FushiContinueHero), findsOneWidget);
    // 竖封面 + 剧照混排：一行，按行高定宽，顶底对齐。
    expect(find.byType(GridView), findsNothing);
    final Rect still = tester.getRect(
      find.byKey(const ValueKey<String>('spot-1')),
    );
    final Rect poster = tester.getRect(
      find.byKey(const ValueKey<String>('spot-2')),
    );
    expect(still.width / still.height, closeTo(16 / 9, 0.01));
    expect(poster.width / poster.height, closeTo(2 / 3, 0.01));
    expect(poster.height, closeTo(still.height, 0.5));
    expect(poster.top, closeTo(still.top, 0.5));
    // 主卡与封面行等高并排（行高含悬停余量）。
    final Rect main = tester.getRect(
      find.byKey(const ValueKey<String>('spot-0')),
    );
    final Rect row = tester.getRect(
      find.byKey(const ValueKey<String>('fushi-continue-side-row')),
    );
    expect(row.left, greaterThan(main.right));
    expect(row.height, closeTo(main.height, 1));
  });

  testWidgets('窄屏：主卡在上、封面是下方横滑行，能用鼠标横拖', (WidgetTester tester) async {
    await pumpAt(tester, 400, stills(6));
    expect(tester.takeException(), isNull);
    expect(find.byType(GridView), findsNothing);
    final ListView list = tester.widget<ListView>(find.byType(ListView));
    expect(list.scrollDirection, Axis.horizontal);

    final Rect main = tester.getRect(
      find.byKey(const ValueKey<String>('spot-0')),
    );
    final Rect side = tester.getRect(
      find.byKey(const ValueKey<String>('spot-1')),
    );
    expect(main.width, closeTo(400, 0.5));
    expect(side.top, greaterThan(main.bottom));

    final ScrollPosition position = sidePosition(tester, ListView);
    await tester.drag(
      find.byType(ListView),
      const Offset(-200, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('库页窄屏不挂封面行（下面有自己的「最近」行）', (WidgetTester tester) async {
    await pumpAt(tester, 400, <FushiContinueEntry>[
      entry(0, still: false),
      entry(1, still: false),
    ], showSideWhenNarrow: false);
    expect(find.byKey(const ValueKey<String>('spot-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('spot-1')), findsNothing);
    expect(FushiContinueSpotlight.sideBySide(400, 1), isFalse);
    expect(FushiContinueSpotlight.sideBySide(1200, 1), isTrue);
    expect(FushiContinueSpotlight.sideBySide(1200, 0), isFalse);
  });

  testWidgets('点按续播、长按出条目菜单（卡上没有按钮）', (WidgetTester tester) async {
    await pumpAt(tester, 1200, <FushiContinueEntry>[
      entry(0),
      entry(1),
      entry(2, still: false),
    ]);
    await tester.tap(find.byKey(const ValueKey<String>('spot-0')));
    await tester.tap(find.byKey(const ValueKey<String>('spot-2')));
    await tester.pumpAndSettle();
    expect(opened, <String>['0', '2']);

    await tester.longPress(find.byKey(const ValueKey<String>('spot-1')));
    await tester.pumpAndSettle();
    expect(menus, <String>['1']);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('剧照小卡压完整的短副标题，主卡是完整眉标', (WidgetTester tester) async {
    await pumpAt(tester, 1200, stills(3));
    // 「下一集 · 第 N 集」按 ' · ' 切开只剩「下一集」，集数就丢了。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('spot-1')),
        matching: find.text('Next · Episode 2'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('spot-0')),
        matching: find.text('Next · Episode 1 · 3 watched'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('只有一个条目时只画主卡，不出空的横滑区', (WidgetTester tester) async {
    for (final double width in <double>[1200, 400]) {
      for (final bool still in <bool>[true, false]) {
        await pumpAt(tester, width, <FushiContinueEntry>[
          entry(0, still: still),
        ]);
        expect(find.byKey(const ValueKey<String>('spot-0')), findsOneWidget);
        expect(find.byType(GridView), findsNothing);
        expect(find.byType(ListView), findsNothing);
      }
    }
  });

  testWidgets('外层已整块进场时（staggerEntrance: false）组件内不再叠进场动画', (
    WidgetTester tester,
  ) async {
    final Finder spotlight = find.byType(FushiContinueSpotlight);
    final Finder inner = find.descendant(
      of: spotlight,
      matching: find.byType(FushiStaggeredEntrance),
    );
    // 宽屏剧照主卡 / 宽屏竖封面主卡 / 窄屏，主卡与封面行都要覆盖到。
    for (final double width in <double>[1200, 400]) {
      for (final bool still in <bool>[true, false]) {
        final List<FushiContinueEntry> entries = <FushiContinueEntry>[
          entry(0, still: still),
          entry(1),
          entry(2, still: false),
        ];
        await pumpAt(tester, width, entries, staggerEntrance: false);
        expect(inner, findsNothing, reason: 'width=$width still=$still');
        // 对照：默认（库页 / 视频首页）仍错峰进场。
        await pumpAt(tester, width, entries);
        expect(inner, findsWidgets, reason: 'width=$width still=$still');
      }
    }
  });

  testWidgets('封面行小卡对读屏只是一个按钮节点（封面卡与文字块不再各读一遍）', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await pumpAt(tester, 1200, <FushiContinueEntry>[
      entry(0),
      entry(1),
      entry(2, still: false),
    ]);
    for (final int i in <int>[1, 2]) {
      final Finder tile = find.ancestor(
        of: find.byKey(ValueKey<String>('spot-$i')),
        matching: find.byType(FushiContinueSideTile),
      );
      expect(tile, findsOneWidget);
      final Finder container = find.descendant(
        of: tile,
        matching: find.byWidgetPredicate(
          (Widget w) => w is Semantics && w.properties.button == true,
        ),
      );
      expect(container, findsOneWidget, reason: 'tile $i');
      final SemanticsNode node = tester.getSemantics(container);
      final SemanticsData data = node.getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue, reason: 'tile $i');
      expect(data.label, contains('Work $i'));
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(data.hasAction(SemanticsAction.longPress), isTrue);
      // 子树里没有别的按钮节点。
      int buttons = 0;
      void visit(SemanticsNode n) {
        if (n.getSemanticsData().flagsCollection.isButton) buttons++;
        n.visitChildren((SemanticsNode c) {
          visit(c);
          return true;
        });
      }

      visit(node);
      expect(buttons, 1, reason: 'tile $i');
    }

    // 文字块长按 / 右键也出条目菜单（与封面卡同一约定）。
    final Finder meta = find
        .byKey(const ValueKey<String>('fushi-continue-tile-meta'))
        .first;
    await tester.longPress(meta);
    await tester.pumpAndSettle();
    expect(menus, isNotEmpty);
    semantics.dispose();
  });
}
