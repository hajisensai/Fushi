import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_continue_blocks.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/cover_provider_epoch.dart';

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

  // 主卡 / 封面行是封面网格布局（与墨水屏）下的皮；重设计外壳的色块布局下整段
  // 换成一行色块横滑（见文件末尾那条用例），所以默认钉在网格布局。
  Widget harness(
    double width,
    List<FushiContinueEntry> entries, {
    bool showSideWhenNarrow = true,
    bool staggerEntrance = true,
    ShellContentLayout layout = ShellContentLayout.grid,
    String? blockLabel,
    bool blockLeadingHero = false,
  }) => MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[
        const FushiEinkTheme(false),
        FushiShellTheme(contentLayout: layout),
      ],
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
              blockLabel: blockLabel,
              blockLeadingHero: blockLeadingHero,
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

  testWidgets('窄屏剧照封面行：卡下只留一行片名的高度，不按竖卡留副行 / 进度条位', (
    WidgetTester tester,
  ) async {
    // 用户 2026-11-02「窄屏间隙大」：剧照小卡的副标题与进度压在剧照上，卡下
    // 只有片名；文字块按竖封面卡「两行标题 + 副行 + 进度条」留高时，封面行
    // 下面到下一区块空出一大截。
    await pumpAt(tester, 400, stills(6));
    final Finder meta = find.byKey(
      const ValueKey<String>('fushi-continue-tile-meta'),
    );
    final BuildContext context = tester.element(meta.first);
    final double compact = ShelfCardMeta.heightFor(
      context,
      titleLines: kContinueStillTileTitleLines,
      titleOnly: true,
    );
    expect(tester.getSize(meta.first).height, closeTo(compact, 0.01));
    expect(compact, lessThan(ShelfCardMeta.heightFor(context) - 20));
    // 行高 = 剧照 + 一行片名 + 上下悬停余量，行底不再拖着空白。
    final Rect row = tester.getRect(
      find.byKey(const ValueKey<String>('fushi-continue-side-row')),
    );
    final Rect tileMeta = tester.getRect(meta.first);
    expect(row.bottom - tileMeta.bottom, lessThan(16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('混排封面行（剧照 + 竖封面）：文字块按整卡留高，剧照卡与竖卡标题行数一致', (
    WidgetTester tester,
  ) async {
    // 行高与卡内文字块形态必须同源：行按整卡留高时，剧照卡不能自己截成一行
    // 片名、下面空着（审查 PR #2788）。
    await pumpAt(tester, 400, <FushiContinueEntry>[
      entry(0),
      entry(1),
      entry(2, still: false),
      entry(3),
    ]);
    expect(tester.takeException(), isNull);
    final Finder meta = find.byKey(
      const ValueKey<String>('fushi-continue-tile-meta'),
    );
    expect(meta, findsNWidgets(3));
    final double full = ShelfCardMeta.heightFor(tester.element(meta.first));
    for (int i = 0; i < 3; i++) {
      expect(tester.getSize(meta.at(i)).height, closeTo(full, 0.01));
    }
    final Iterable<ShelfTitleLine> titles = tester.widgetList<ShelfTitleLine>(
      find.descendant(of: meta, matching: find.byType(ShelfTitleLine)),
    );
    expect(titles, hasLength(3));
    for (final ShelfTitleLine t in titles) {
      expect(t.maxLines, kShelfCardMetaTitleLines);
    }
  });

  testWidgets('宽屏并排全剧照封面行：文字块只留一行片名，行内无溢出', (WidgetTester tester) async {
    await pumpAt(tester, 1200, stills(6));
    expect(tester.takeException(), isNull);
    final Finder meta = find.byKey(
      const ValueKey<String>('fushi-continue-tile-meta'),
    );
    expect(meta, findsWidgets);
    final double compact = ShelfCardMeta.heightFor(
      tester.element(meta.first),
      titleLines: kContinueStillTileTitleLines,
      titleOnly: true,
    );
    final int count = meta.evaluate().length;
    for (int i = 0; i < count; i++) {
      expect(tester.getSize(meta.at(i)).height, closeTo(compact, 0.01));
    }
    for (final ShelfTitleLine t in tester.widgetList<ShelfTitleLine>(
      find.descendant(of: meta, matching: find.byType(ShelfTitleLine)),
    )) {
      expect(t.maxLines, kContinueStillTileTitleLines);
    }
    // 封面 + 文字块不越出封面行。
    final Rect row = tester.getRect(
      find.byKey(const ValueKey<String>('fushi-continue-side-row')),
    );
    for (int i = 0; i < count; i++) {
      expect(tester.getRect(meta.at(i)).bottom, lessThanOrEqualTo(row.bottom));
    }
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
  // 用户反馈 me_DAkqFJ_（首页「继续」并排封面行）：视频条目声明竖海报比例、
  // 解码出横图后按 16:9 剧照画；横向悬停余量若按声明的竖图比例留，首张卡
  // 放大后左缘超出 ListView 视口被裁，标题首字缺一截。
  testWidgets('方向待探测的条目解出横图：悬停放大后的首张卡整张留在视口内', (WidgetTester tester) async {
    const _PendingImage image = _PendingImage('spot-probed-landscape');
    CoverProbeMemo.rememberAspect(
      image,
      16 / 9,
      epoch: CoverProviderEpoch.of(image),
    );
    addTearDown(() => CoverProbeMemo.evict(image));
    final FushiContinueEntry probed = FushiContinueEntry(
      key: const ValueKey<String>('spot-1'),
      focusId: const FushiFocusId('spot-1'),
      title: 'Work 1',
      subtitle: 'Next · Episode 2',
      cover: const ColoredBox(color: Color(0xFF304050)),
      coverAspectRatio: 2 / 3,
      orientationImage: image,
      progress: 0.5,
      onOpen: () {},
    );
    await pumpAt(tester, 1200, <FushiContinueEntry>[
      entry(0),
      probed,
      entry(2, still: false),
    ]);
    expect(tester.takeException(), isNull);
    final Finder card = find.byKey(const ValueKey<String>('spot-1'));
    final Size rest = tester.getSize(card);
    // 确实按 16:9 剧照画了（否则下面的包含关系不说明问题）。
    expect(rest.width / rest.height, closeTo(16 / 9, 0.01));

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(card));
    await tester.pumpAndSettle();
    final Rect lifted = tester.getRect(card);
    final Rect viewport = tester.getRect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(lifted.width, greaterThan(rest.width));
    expect(lifted.left, greaterThanOrEqualTo(viewport.left - 0.01));
    expect(lifted.right, lessThanOrEqualTo(viewport.right + 0.01));
  });

  // 2026-11-12 用户：「继续阅读占空间太大了还是保持跟之前一样侧滑」——色块布局下
  // 「继续」区是一行半高色块横滑（书架 / 漫画 / 视频 / 游戏 / 音乐同一个组件），
  // 不再是拼贴主块 + 多行大色块。
  for (final ShellContentLayout layout in <ShellContentLayout>[
    ShellContentLayout.collage,
  ]) {
    testWidgets('色块布局（${layout.name}）：全部条目一行横滑，上方分区标题', (
      WidgetTester tester,
    ) async {
      final List<FushiContinueEntry> entries = <FushiContinueEntry>[
        for (int i = 0; i < 6; i++) entry(i),
      ];
      await tester.pumpWidget(
        harness(1200, entries, layout: layout, blockLabel: 'Continue'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Continue'), findsOneWidget);
      final Finder row = find.byKey(
        const ValueKey<String>('fushi-continue-side-row'),
      );
      expect(row, findsOneWidget);
      expect(tester.getSize(row).height, FushiCoverBlockStrip.rowHeight());
      final Rect first = tester.getRect(
        find.byKey(const ValueKey<String>('spot-0')),
      );
      final Rect second = tester.getRect(
        find.byKey(const ValueKey<String>('spot-1')),
      );
      expect(
        first.size,
        Size(kFushiCoverBlockStripTileWidth, FushiCoverBlockStrip.rowHeight()),
      );
      expect(second.top, first.top, reason: '同一行');
      expect(second.left, greaterThan(first.right));
      expect(
        tester
            .widgetList<ListView>(
              find.descendant(of: row, matching: find.byType(ListView)),
            )
            .single
            .scrollDirection,
        Axis.horizontal,
      );
    });
  }

  testWidgets('色块布局 + blockLeadingHero（视频首页）：首条是大封面主块，其余在旁边横滑', (
    WidgetTester tester,
  ) async {
    final List<FushiContinueEntry> entries = <FushiContinueEntry>[
      for (int i = 0; i < 8; i++) entry(i),
    ];
    await tester.pumpWidget(
      harness(
        1200,
        entries,
        layout: ShellContentLayout.collage,
        blockLabel: 'Watching',
        blockLeadingHero: true,
      ),
    );
    await tester.pumpAndSettle();

    // 区块名作主块的状态 chip，不另画分区标题。
    expect(find.text('Watching'), findsOneWidget);
    expect(find.byType(FushiBlockSectionTitle), findsNothing);
    final Rect hero = tester.getRect(
      find.byKey(const ValueKey<String>('spot-0')),
    );
    final Rect side = tester.getRect(
      find.byKey(const ValueKey<String>('spot-1')),
    );
    expect(hero.height, kFushiCoverBlockHeroHeight);
    expect(side.height, FushiCoverBlockStrip.rowHeight());
    expect(side.left, greaterThan(hero.right), reason: '其余条目在主块旁边');
    expect(side.top, hero.top);
  });
}

/// 永不解码完的图：方向只靠预先记进 [CoverProbeMemo] 的结论，不触发解码失败。
class _PendingImage extends ImageProvider<_PendingImage> {
  const _PendingImage(this.name);

  final String name;

  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_PendingImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _PendingImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Completer<ImageInfo>().future);

  @override
  bool operator ==(Object other) =>
      other is _PendingImage && other.name == name;

  @override
  int get hashCode => name.hashCode;
}
