import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart'
    show mangaSelectionRectFromPayload;
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiToolbarFab, kFushiFloatingToolbarExtent;

void main() {
  group('mangaChromeTopInset', () {
    test('悬浮 / 界面隐藏 → 0；固定且可见 → 状态栏 + 栏高', () {
      expect(
        mangaChromeTopInset(
          floating: true,
          chromeVisible: true,
          statusBarInset: 24,
        ),
        0,
      );
      expect(
        mangaChromeTopInset(
          floating: false,
          chromeVisible: false,
          statusBarInset: 24,
        ),
        0,
      );
      expect(
        mangaChromeTopInset(
          floating: false,
          chromeVisible: true,
          statusBarInset: 24,
        ),
        24 + kMangaChromeBarHeight,
      );
    });
  });

  group('mangaChromeBarPainted', () {
    test('固定态只看 chromeVisible；悬浮态还要 transientVisible', () {
      expect(
        mangaChromeBarPainted(
          floating: false,
          chromeVisible: true,
          transientVisible: false,
          contentReady: true,
        ),
        isTrue,
      );
      expect(
        mangaChromeBarPainted(
          floating: true,
          chromeVisible: true,
          transientVisible: false,
          contentReady: true,
        ),
        isFalse,
      );
      expect(
        mangaChromeBarPainted(
          floating: true,
          chromeVisible: true,
          transientVisible: true,
          contentReady: true,
        ),
        isTrue,
      );
      // 没有正文（加载失败 / 未下载）：悬浮态也无条件画——没有 WebView 就没有
      // 中央点击这条唤出通道，返回键收起就是 iOS 死锁。
      expect(
        mangaChromeBarPainted(
          floating: true,
          chromeVisible: true,
          transientVisible: false,
          contentReady: false,
        ),
        isTrue,
      );
      // M 键隐藏界面：两种形态都不画（悬浮唤出态也压不过用户意图）。
      expect(
        mangaChromeBarPainted(
          floating: true,
          chromeVisible: false,
          transientVisible: true,
          contentReady: true,
        ),
        isFalse,
      );
    });
  });

  group('mangaSelectionRectFromPayload', () {
    test('固定态 WebView 让位后选区矩形整体下移 viewportOrigin', () {
      final ReaderSelectionData data = ReaderSelectionData.fromJson(
        <String, dynamic>{
          'text': 'x',
          'sentence': 'x',
          'rect': <String, dynamic>{
            'x': 10.0,
            'y': 20.0,
            'width': 30.0,
            'height': 40.0,
          },
        },
      );
      expect(
        mangaSelectionRectFromPayload(
          data,
          fallbackScreen: const Size(800, 600),
          viewportOrigin: const Offset(0, 72),
        ),
        const Rect.fromLTWH(10, 92, 30, 40),
      );
      // 无 rect 的兜底：WebView 中心再加偏移。
      final ReaderSelectionData noRect = ReaderSelectionData.fromJson(
        <String, dynamic>{'text': 'x', 'sentence': 'x'},
      );
      expect(
        mangaSelectionRectFromPayload(
          noRect,
          fallbackScreen: const Size(800, 528),
          viewportOrigin: const Offset(0, 72),
        ).center,
        const Offset(400, 264 + 72),
      );
    });
  });

  // ── 2026-10 M3E 悬浮工具栏（与小说阅读器统一）────────────────────────────

  /// 与 manga_fushi_page._chromeActionGroups 同形的动作表（书架在线条目、spread
  /// 模式、桌面全屏可用）。
  List<List<MangaChromeAction>> pageLikeGroups({
    VoidCallback? onChapters,
    VoidCallback? onQuick,
    VoidCallback? onStart,
    VoidCallback? onHide,
    bool ocrRunning = false,
  }) {
    void noop() {}
    return <List<MangaChromeAction>>[
      <MangaChromeAction>[
        MangaChromeAction(
          key: const ValueKey<String>('chapters'),
          icon: Icons.list_alt_outlined,
          label: '章节',
          priority: 8,
          onPressed: onChapters ?? noop,
        ),
        MangaChromeAction(
          key: const ValueKey<String>('grid'),
          icon: Icons.grid_view_rounded,
          label: '页面一览',
          priority: 4,
          onPressed: noop,
        ),
      ],
      <MangaChromeAction>[
        MangaChromeAction(
          key: const ValueKey<String>('mode'),
          icon: Icons.auto_stories_outlined,
          label: '阅读模式',
          priority: 6,
          onPressed: noop,
        ),
        MangaChromeAction(
          key: const ValueKey<String>('spread'),
          icon: Icons.auto_awesome_motion_outlined,
          label: '双页',
          priority: 3,
          onPressed: noop,
        ),
        MangaChromeAction(
          key: const ValueKey<String>('direction'),
          icon: Icons.arrow_back,
          label: '从右到左',
          priority: 2,
          onPressed: noop,
        ),
      ],
      <MangaChromeAction>[
        MangaChromeAction(
          key: const ValueKey<String>('quick'),
          icon: Icons.tune_rounded,
          label: '快捷设置',
          priority: 10,
          onPressed: onQuick ?? noop,
        ),
      ],
      <MangaChromeAction>[
        if (ocrRunning)
          MangaChromeAction(
            key: const ValueKey<String>('cancel'),
            icon: Icons.stop_circle_outlined,
            label: '取消',
            slot: MangaChromeSlot.top,
            priority: 9,
            onPressed: noop,
          ),
        MangaChromeAction(
          key: const ValueKey<String>('fullscreen'),
          icon: Icons.fullscreen_rounded,
          label: '全屏',
          slot: MangaChromeSlot.top,
          priority: 7,
          onPressed: noop,
        ),
        MangaChromeAction(
          key: const ValueKey<String>('start'),
          icon: Icons.last_page,
          label: '回到开头',
          slot: MangaChromeSlot.top,
          priority: 1,
          onPressed: onStart ?? noop,
        ),
        MangaChromeAction(
          key: const ValueKey<String>('hide'),
          icon: Icons.visibility_off_outlined,
          label: '隐藏界面',
          slot: MangaChromeSlot.top,
          active: true,
          onPressed: onHide ?? noop,
        ),
      ],
    ];
  }

  List<Object?> keysOf(Iterable<MangaChromeAction> actions) => <Object?>[
    for (final MangaChromeAction a in actions)
      (a.key! as ValueKey<String>).value,
  ];

  group('planMangaChrome（底部工具栏 / 右上角动作）', () {
    test('桌面宽屏：工具栏动作全在工具栏；右上角 = 顶栏动作按优先级从高到低', () {
      final MangaChromePlan plan = planMangaChrome(
        width: 1600,
        groups: pageLikeGroups(),
        hasFab: true,
      );
      expect(plan.toolbar.map(keysOf).toList(), <List<Object?>>[
        <Object?>['chapters', 'grid'],
        <Object?>['mode', 'spread', 'direction'],
        <Object?>['quick'],
      ]);
      expect(keysOf(plan.top), <Object?>['fullscreen', 'start', 'hide']);
    });

    test('400dp 手机：纯图标工具栏放不下时按优先级从低到高降到右上角', () {
      final MangaChromePlan plan = planMangaChrome(
        width: 400,
        groups: pageLikeGroups(),
        hasFab: true,
      );
      final List<Object?> kept = <Object?>[
        for (final List<MangaChromeAction> g in plan.toolbar) ...keysOf(g),
      ];
      // 快捷设置 / 章节 / 阅读模式（高优先级）必须留在拇指区。
      expect(kept, containsAll(<Object?>['quick', 'chapters', 'mode']));
      // 翻页方向优先级最低，最先降级；纯图标 48dp 下只需降这一颗。
      expect(kept, isNot(contains('direction')));
      expect(kept, hasLength(5));
      // 降下来的按优先级混排进右上角（方向 2 排在全屏 7 之后、回到开头 1 之前）。
      expect(keysOf(plan.top), <Object?>[
        'fullscreen',
        'direction',
        'start',
        'hide',
      ]);
      // 留下的部分（含 FAB）确实放得下。
      expect(
        mangaToolbarWidth(groups: plan.toolbar, hasFab: true),
        lessThanOrEqualTo(400 - 2 * kMangaChromeEdgeInset),
      );
    });

    test('越窄降得越多，但每档都放得下；动作一个不少；极窄也不抛', () {
      for (final double width in <double>[1024, 720, 600, 480, 412, 360, 320]) {
        final MangaChromePlan plan = planMangaChrome(
          width: width,
          groups: pageLikeGroups(),
          hasFab: true,
        );
        final double available = (width - 2 * kMangaChromeEdgeInset).clamp(
          0,
          kMangaChromeBottomMaxWidth,
        );
        expect(
          mangaToolbarWidth(groups: plan.toolbar, hasFab: true),
          lessThanOrEqualTo(available),
          reason: '$width dp 下工具栏不得溢出',
        );
        final int total =
            plan.toolbar.fold<int>(
              0,
              (int n, List<MangaChromeAction> g) => n + g.length,
            ) +
            plan.top.length;
        expect(total, 9, reason: '$width dp：动作一个不少（不删功能）');
        final List<int> priorities = <int>[
          for (final MangaChromeAction a in plan.top) a.priority,
        ];
        expect(
          priorities,
          orderedEquals(
            List<int>.of(priorities)..sort((int a, int b) => b - a),
          ),
          reason: '$width dp：右上角按优先级从高到低排',
        );
      }
      expect(
        () => planMangaChrome(width: 0, groups: pageLikeGroups(), hasFab: true),
        returnsNormally,
      );
    });

    test('整卷 OCR 运行中：取消钮排在右上角最前（最后才收）', () {
      final MangaChromePlan plan = planMangaChrome(
        width: 360,
        groups: pageLikeGroups(ocrRunning: true),
        hasFab: true,
      );
      expect(keysOf(plan.top).first, 'cancel');
      expect(keysOf(plan.top), containsAll(<Object?>['cancel', 'fullscreen']));
    });
  });

  Widget chromeHost({
    required double width,
    double textScale = 1,
    VoidCallback? onTitle,
    VoidCallback? onChapters,
    VoidCallback? onQuick,
    VoidCallback? onStart,
    VoidCallback? onHide,
    ValueChanged<int>? onCommitted,
  }) {
    final ValueNotifier<int> page = ValueNotifier<int>(4);
    final MangaChromePlan plan = planMangaChrome(
      width: width,
      groups: pageLikeGroups(
        onChapters: onChapters,
        onQuick: onQuick,
        onStart: onStart,
        onHide: onHide,
      ),
      hasFab: true,
    );
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 900),
          padding: const EdgeInsets.only(top: 20),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: MangaReaderTopBar(
                  key: const ValueKey<String>('top'),
                  title: '第12話 夜明けの約束 そして長い長い副題',
                  subtitle: '星降る街の図書館',
                  floating: true,
                  backTooltip: 'back',
                  onBack: () {},
                  onTitleTap: onTitle ?? () {},
                  status: const MangaChromeStatusChip(
                    key: ValueKey<String>('chip'),
                    text: '分镜 3',
                  ),
                  actions: plan.top,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: MangaReaderBottomChrome(
                  slider: ExcludeFocus(
                    child: MangaReaderBottomBar(
                      pageCount: 40,
                      pageListenable: page,
                      currentPage: () => page.value,
                      rtl: true,
                      onPageCommitted: onCommitted ?? (_) {},
                      onPageTap: () {},
                    ),
                  ),
                  toolbar: MangaReaderToolbar(
                    groups: plan.toolbar,
                    fab: FushiToolbarFab(
                      key: const ValueKey<String>('fab'),
                      icon: Icons.highlight_alt,
                      tooltip: 'OCR',
                      rounded: true,
                      morphing: true,
                      onPressed: () {},
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void setSize(WidgetTester tester, double width) {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('MangaReaderTopBar（悬浮胶囊）', () {
    testWidgets('返回 / 标题 / 动作三块独立胶囊；栏高与让位量同源；点标题 = 导航', (
      WidgetTester tester,
    ) async {
      setSize(tester, 1600);
      int titleTaps = 0;
      await tester.pumpWidget(
        chromeHost(width: 1600, onTitle: () => titleTaps++),
      );
      for (final String k in <String>[
        'manga_reader_back_pill',
        'manga_reader_title_pill',
        'manga_reader_action_pill',
      ]) {
        expect(find.byKey(ValueKey<String>(k)), findsOneWidget, reason: k);
      }
      final Rect back = tester.getRect(
        find.byKey(const ValueKey<String>('manga_reader_back_pill')),
      );
      final Rect title = tester.getRect(
        find.byKey(const ValueKey<String>('manga_reader_title_pill')),
      );
      final Rect action = tester.getRect(
        find.byKey(const ValueKey<String>('manga_reader_action_pill')),
      );
      expect(back.right, lessThan(title.left), reason: '胶囊之间留缝，正文露出来');
      expect(title.right, lessThan(action.left));
      expect(find.byKey(const ValueKey<String>('chip')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('top'))).height,
        20 + kMangaChromeBarHeight,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_reader_title_button')),
      );
      expect(titleTaps, 1);
    });

    for (final double width in <double>[1200, 1600]) {
      testWidgets('$width 宽：右上角动作默认全部平铺，不画「⋯」，点按生效', (
        WidgetTester tester,
      ) async {
        setSize(tester, width);
        int starts = 0;
        await tester.pumpWidget(
          chromeHost(width: width, onStart: () => starts++),
        );
        expect(
          find.byKey(const ValueKey<String>('manga_chrome_overflow')),
          findsNothing,
          reason: '空间够时不收起',
        );
        final Rect pill = tester.getRect(
          find.byKey(const ValueKey<String>('manga_reader_action_pill')),
        );
        for (final String k in <String>['fullscreen', 'start', 'hide']) {
          final Finder f = find.byKey(ValueKey<String>(k));
          expect(f, findsOneWidget, reason: '$k 平铺在右上角');
          expect(pill.contains(tester.getCenter(f)), isTrue, reason: k);
        }
        // 平铺顺序 = 优先级从高到低（最常用的在最左、最后才收）。
        expect(
          tester.getCenter(find.byKey(const ValueKey<String>('fullscreen'))).dx,
          lessThan(
            tester.getCenter(find.byKey(const ValueKey<String>('start'))).dx,
          ),
        );
        await tester.tap(find.byKey(const ValueKey<String>('start')));
        expect(starts, 1);
      });
    }

    testWidgets('400 宽：放不下的按优先级收进「⋯」，菜单里能触发；开关项带勾', (
      WidgetTester tester,
    ) async {
      setSize(tester, 400);
      int starts = 0;
      int hides = 0;
      await tester.pumpWidget(
        chromeHost(width: 400, onStart: () => starts++, onHide: () => hides++),
      );
      expect(tester.takeException(), isNull);
      // 400dp：标题保底 160 之后只放得下一颗 + ⋯；平铺的是优先级最高的全屏。
      expect(find.byKey(const ValueKey<String>('fullscreen')), findsOneWidget);
      for (final String k in <String>['direction', 'start', 'hide']) {
        expect(
          find.byKey(ValueKey<String>(k)),
          findsNothing,
          reason: '$k 收进 ⋯',
        );
      }
      final Finder overflow = find.byKey(
        const ValueKey<String>('manga_chrome_overflow'),
      );
      expect(overflow, findsOneWidget);
      final Rect action = tester.getRect(
        find.byKey(const ValueKey<String>('manga_reader_action_pill')),
      );
      expect(action.right, lessThanOrEqualTo(400));
      await tester.tap(overflow);
      await tester.pumpAndSettle();
      final List<Object?> items = <Object?>[
        for (final PopupMenuItem<MangaChromeAction> item
            in tester.widgetList<PopupMenuItem<MangaChromeAction>>(
              find.byType(PopupMenuItem<MangaChromeAction>),
            ))
          (item.value!.key! as ValueKey<String>).value,
      ];
      expect(items, <Object?>['direction', 'start', 'hide']);
      expect(find.byIcon(Icons.check), findsOneWidget, reason: '开关项带勾');
      await tester.tap(find.byKey(const ValueKey<String>('start_menu_item')));
      await tester.pumpAndSettle();
      expect(starts, 1, reason: '「⋯」菜单项能触发动作');
      await tester.tap(overflow);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('hide_menu_item')));
      await tester.pumpAndSettle();
      expect(hides, 1);
    });

    testWidgets('窗口缩放：窄 → 宽展开、宽 → 窄收起', (WidgetTester tester) async {
      Future<void> pumpAt(double width) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(chromeHost(width: width));
      }

      addTearDown(tester.view.reset);
      final Finder overflow = find.byKey(
        const ValueKey<String>('manga_chrome_overflow'),
      );
      await pumpAt(400);
      expect(overflow, findsOneWidget);
      await pumpAt(1600);
      expect(overflow, findsNothing, reason: '拉宽后默认展开');
      await pumpAt(400);
      expect(overflow, findsOneWidget, reason: '缩窄后放不下再收起');
    });

    for (final double scale in <double>[1.0, 1.3, 2.0]) {
      testWidgets('412dp × 字号 $scale：标题胶囊不压动作胶囊，无溢出', (
        WidgetTester tester,
      ) async {
        setSize(tester, 412);
        await tester.pumpWidget(chromeHost(width: 412, textScale: scale));
        expect(tester.takeException(), isNull);
        final Rect title = tester.getRect(
          find.byKey(const ValueKey<String>('manga_reader_title_pill')),
        );
        final Rect action = tester.getRect(
          find.byKey(const ValueKey<String>('manga_reader_action_pill')),
        );
        expect(title.right, lessThanOrEqualTo(action.left));
        expect(action.right, lessThanOrEqualTo(412));
        final RenderParagraph p = tester.renderObject<RenderParagraph>(
          find.byKey(const ValueKey<String>('manga_reader_title')),
        );
        expect(p.size.width, greaterThan(0));
      });
    }
  });

  group('底部悬浮工具栏（纯图标）', () {
    for (final double width in <double>[420, 1600]) {
      testWidgets('$width 宽：无文字，tooltip + 语义名 = 原文案，命中区 ≥ 48，点按生效', (
        WidgetTester tester,
      ) async {
        setSize(tester, width);
        final SemanticsHandle semantics = tester.ensureSemantics();
        int quick = 0;
        int chapters = 0;
        await tester.pumpWidget(
          chromeHost(
            width: width,
            onQuick: () => quick++,
            onChapters: () => chapters++,
          ),
        );
        final Finder toolbar = find.byKey(
          const ValueKey<String>('manga_reader_toolbar'),
        );
        expect(toolbar, findsOneWidget);
        for (final (String key, String label) in <(String, String)>[
          ('chapters', '章节'),
          ('grid', '页面一览'),
          ('mode', '阅读模式'),
          ('quick', '快捷设置'),
        ]) {
          final Finder button = find.byKey(ValueKey<String>(key));
          expect(
            find.descendant(of: toolbar, matching: button),
            findsOneWidget,
            reason: key,
          );
          expect(
            find.descendant(of: toolbar, matching: find.text(label)),
            findsNothing,
            reason: '$key：底栏不画文字',
          );
          expect(
            find.byTooltip(label),
            findsOneWidget,
            reason: '$key：名称进 tooltip',
          );
          expect(
            find.descendant(
              of: toolbar,
              matching: find.bySemanticsLabel(label),
            ),
            findsWidgets,
            reason: '$key：无障碍名 = 原文案',
          );
          final Size size = tester.getSize(button);
          expect(size.width, greaterThanOrEqualTo(48), reason: key);
          expect(size.height, greaterThanOrEqualTo(48), reason: key);
        }
        // 纯图标浮动工具栏：没有组间竖分隔线（1 宽的 ColoredBox）。
        expect(
          find.descendant(
            of: toolbar,
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is SizedBox && w.width == 1 && w.child is ColoredBox,
            ),
          ),
          findsNothing,
        );
        expect(
          tester
              .getSize(
                find.descendant(
                  of: toolbar,
                  matching: find.byKey(
                    const ValueKey<String>('fushi_floating_toolbar'),
                  ),
                ),
              )
              .height,
          kFushiFloatingToolbarExtent,
        );
        await tester.tap(find.byKey(const ValueKey<String>('quick')));
        await tester.tap(find.byKey(const ValueKey<String>('chapters')));
        expect(quick, 1);
        expect(chapters, 1);
        semantics.dispose();
      });
    }

    testWidgets('手机：FAB 配在工具栏旁；页码滑块胶囊在工具栏上方', (WidgetTester tester) async {
      setSize(tester, 420);
      await tester.pumpWidget(chromeHost(width: 420));
      final Rect slider = tester.getRect(
        find.byKey(const ValueKey<String>('manga_reader_slider_pill')),
      );
      final Rect toolbar = tester.getRect(
        find.byKey(const ValueKey<String>('manga_reader_toolbar')),
      );
      final Rect fab = tester.getRect(
        find.byKey(const ValueKey<String>('fab')),
      );
      expect(slider.bottom, lessThanOrEqualTo(toolbar.top));
      expect(fab.left, greaterThan(toolbar.right), reason: 'FAB 配在工具栏旁');
      expect(toolbar.left, greaterThanOrEqualTo(kMangaChromeEdgeInset));
      expect(fab.right, lessThanOrEqualTo(420 - kMangaChromeEdgeInset + 0.5));
    });

    testWidgets('页码滑块可用：拖动松手提交一次', (WidgetTester tester) async {
      setSize(tester, 1600);
      final List<int> committed = <int>[];
      await tester.pumpWidget(
        chromeHost(width: 1600, onCommitted: committed.add),
      );
      final Finder slider = find.byKey(
        const ValueKey<String>('manga_page_slider'),
      );
      expect(slider, findsOneWidget);
      await tester.drag(slider, const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(committed, hasLength(1));
      // RTL：往物理左拖 = 往后翻。
      expect(committed.single, greaterThan(4));
    });

    testWidgets('焦点可遍历：Tab 走遍顶栏与工具栏按钮和 FAB，滑块不进遍历；Enter 触发', (
      WidgetTester tester,
    ) async {
      // 400dp：右上角有「⋯」，同时验证它也在焦点遍历里。
      setSize(tester, 400);
      int quick = 0;
      await tester.pumpWidget(chromeHost(width: 400, onQuick: () => quick++));
      final Set<String> visited = <String>{};
      bool sliderFocused = false;
      for (int i = 0; i < 30; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
        if (ctx == null) continue;
        if (ctx.findAncestorWidgetOfExactType<Slider>() != null) {
          sliderFocused = true;
        }
        final Set<String> here = <String>{};
        if (ctx.widget.key case final ValueKey<String> k) here.add(k.value);
        ctx.visitAncestorElements((Element e) {
          if (e.widget.key case final ValueKey<String> k) here.add(k.value);
          return true;
        });
        visited.addAll(here);
        if (here.contains('quick') && quick == 0) {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
        }
      }
      expect(sliderFocused, isFalse, reason: '滑块拿焦点会吃掉翻页方向键');
      expect(
        visited,
        containsAll(<String>[
          'manga_reader_back_button',
          'manga_reader_title_button',
          'manga_chrome_overflow',
          'fullscreen',
          'chapters',
          'mode',
          'quick',
          'fab',
        ]),
      );
      expect(quick, 1, reason: '焦点到工具栏按钮上按 Enter 触发');
    });
  });

  group('MangaChromeReveal（弹簧显隐）', () {
    Widget reveal(bool visible, {bool reduceMotion = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: MangaChromeReveal(
          visible: visible,
          child: const SizedBox(
            key: ValueKey<String>('bar'),
            width: 100,
            height: 40,
          ),
        ),
      ),
    );

    testWidgets('隐藏：弹簧播完才卸载，途中不吃指针；再显示弹回', (WidgetTester tester) async {
      await tester.pumpWidget(reveal(true));
      expect(find.byKey(const ValueKey<String>('bar')), findsOneWidget);
      await tester.pumpWidget(reveal(false));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        find.byKey(const ValueKey<String>('bar')),
        findsOneWidget,
        reason: '退场途中仍在画',
      );
      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey<String>('bar')),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('bar')), findsNothing);
      await tester.pumpWidget(reveal(true));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('bar')), findsOneWidget);
    });

    testWidgets('减弱动态效果：瞬间到位', (WidgetTester tester) async {
      await tester.pumpWidget(reveal(true, reduceMotion: true));
      await tester.pumpWidget(reveal(false, reduceMotion: true));
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('bar')), findsNothing);
    });
  });
}
