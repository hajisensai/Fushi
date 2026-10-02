import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart'
    show mangaSelectionRectFromPayload;
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show kReaderDesktopHeaderCompactWidth;
import 'package:fushi/src/reader/reader_selection_data.dart';

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

  group('MangaReaderTopBar', () {
    Widget host({required double width, required bool floating}) {
      return MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(top: 20)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                child: MangaReaderTopBar(
                  title: 'Title',
                  floating: floating,
                  backTooltip: 'back',
                  onBack: () {},
                  pageLabel: () => '3-4 / 40',
                  onPageTap: () {},
                  status: const MangaChromeStatusChip(
                    key: ValueKey<String>('chip'),
                    text: '12/40 · DirectML',
                    warning: true,
                  ),
                  groups: <List<MangaChromeAction>>[
                    <MangaChromeAction>[
                      MangaChromeAction(
                        key: const ValueKey<String>('a_pinned'),
                        icon: Icons.list,
                        label: 'A',
                        pinned: true,
                        onPressed: () {},
                      ),
                    ],
                    const <MangaChromeAction>[],
                    <MangaChromeAction>[
                      MangaChromeAction(
                        key: const ValueKey<String>('b_overflow'),
                        icon: Icons.tune,
                        label: 'B',
                        active: true,
                        onPressed: () {},
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('宽窗：全部按钮直接画，返回键 / 页码 / 状态胶囊都在', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(width: kReaderDesktopHeaderCompactWidth + 40, floating: false),
      );
      expect(
        find.byKey(const ValueKey<String>('manga_reader_back_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('manga_page_jump_button')),
        findsOneWidget,
      );
      expect(find.text('3-4 / 40'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('chip')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('a_pinned')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('b_overflow')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manga_chrome_overflow')),
        findsNothing,
      );
      // 栏总高 = 状态栏 + 栏行高（固定态让位量与画出高度同源）。
      final Size size = tester.getSize(find.byType(MangaReaderTopBar));
      expect(size.height, 20 + kMangaChromeBarHeight);
    });

    testWidgets('窄窗：非 pinned 动作折进 ⋮，菜单项带勾', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(width: kReaderDesktopHeaderCompactWidth - 40, floating: true),
      );
      expect(find.byKey(const ValueKey<String>('a_pinned')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('b_overflow')), findsNothing);
      final Finder overflow = find.byKey(
        const ValueKey<String>('manga_chrome_overflow'),
      );
      expect(overflow, findsOneWidget);
      await tester.tap(overflow);
      await tester.pumpAndSettle();
      expect(find.text('B'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });

  // BUG：412dp 竖屏手机上 7~8 颗 pinned 按钮把标题槽挤到 ~68dp，页码胶囊
  // 「4 / 37」画出槽外、被翻页方向按钮压住。排布必须按真实宽度 + 字号算。
  group('MangaReaderTopBar 窄屏排布', () {
    // 与 manga_fushi_page._chromeActionGroups 同形：章节目录在 leading；视图组
    // 方向 / 回到开头是 pinned + secondary，整卷 OCR 运行中多一颗 pinned 取消；
    // 界面组设置 / 隐藏是 pinned。
    Widget phoneHost({
      required double width,
      required double textScale,
      bool ocrRunning = false,
    }) {
      return MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 800),
            padding: const EdgeInsets.only(top: 24),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                child: MangaReaderTopBar(
                  title: 'Series · Chapter 12',
                  floating: true,
                  backTooltip: 'back',
                  onBack: () {},
                  pageLabel: () => '4 / 37',
                  onPageTap: () {},
                  leading: <MangaChromeAction>[
                    MangaChromeAction(
                      key: const ValueKey<String>('chapters'),
                      icon: Icons.list_alt_outlined,
                      label: 'Chapters',
                      pinned: true,
                      onPressed: () {},
                    ),
                  ],
                  groups: <List<MangaChromeAction>>[
                    <MangaChromeAction>[
                      MangaChromeAction(
                        key: const ValueKey<String>('direction'),
                        icon: Icons.arrow_back,
                        label: 'Right to left',
                        pinned: true,
                        secondary: true,
                        onPressed: () {},
                      ),
                      MangaChromeAction(
                        key: const ValueKey<String>('start'),
                        icon: Icons.last_page,
                        label: 'Back to start',
                        pinned: true,
                        secondary: true,
                        onPressed: () {},
                      ),
                      MangaChromeAction(
                        key: const ValueKey<String>('mode'),
                        icon: Icons.auto_stories_outlined,
                        label: 'Mode',
                        onPressed: () {},
                      ),
                      MangaChromeAction(
                        key: const ValueKey<String>('boxes'),
                        icon: Icons.highlight_alt,
                        label: 'Boxes',
                        active: true,
                        onPressed: () {},
                      ),
                      if (ocrRunning)
                        MangaChromeAction(
                          key: const ValueKey<String>('cancel_ocr'),
                          icon: Icons.stop_circle_outlined,
                          label: 'Cancel',
                          pinned: true,
                          onPressed: () {},
                        ),
                    ],
                    <MangaChromeAction>[
                      MangaChromeAction(
                        key: const ValueKey<String>('settings'),
                        icon: Icons.settings_outlined,
                        label: 'Settings',
                        pinned: true,
                        onPressed: () {},
                      ),
                      MangaChromeAction(
                        key: const ValueKey<String>('hide'),
                        icon: Icons.visibility_off_outlined,
                        label: 'Hide',
                        pinned: true,
                        onPressed: () {},
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    /// 页码胶囊与栏内每一颗图标按钮（含返回键与 ⋮）都不相交；[fullText] 时
    /// 还要求胶囊文字没被省略（完整画出）。测试字体 Ahem 每字宽 = 字号，比真机
    /// Roboto 宽一倍多，OCR 运行中多一颗 pinned 时 1.3 倍字号在 Ahem 下确实放不下
    /// 完整文字，那一档只钉「不相交」。
    void expectChipClear(WidgetTester tester, {bool fullText = true}) {
      final Rect chip = tester.getRect(
        find.byKey(const ValueKey<String>('manga_page_jump_button')),
      );
      final Finder buttons = find.descendant(
        of: find.byType(MangaReaderTopBar),
        matching: find.byType(IconButton),
      );
      expect(buttons, findsWidgets);
      for (final Element e in buttons.evaluate()) {
        final Rect r = tester.getRect(find.byElementPredicate((x) => x == e));
        expect(
          chip.overlaps(r),
          isFalse,
          reason: 'page chip $chip overlaps button $r',
        );
      }
      if (!fullText) return;
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        find.text('4 / 37'),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
    }

    for (final double scale in <double>[1.0, 1.3]) {
      testWidgets('412dp × 字号 $scale：胶囊不被按钮压住，次要 pinned 进 ⋮', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(phoneHost(width: 412, textScale: scale));
        expect(tester.takeException(), isNull);
        expectChipClear(tester);
        // 返回 / 章节 / 设置 / 隐藏这几颗主 pinned 始终在栏上。
        for (final String k in <String>['chapters', 'settings', 'hide']) {
          expect(find.byKey(ValueKey<String>(k)), findsOneWidget);
        }
      });

      testWidgets('412dp × 字号 $scale + 整卷 OCR 运行中：胶囊仍完整', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          phoneHost(width: 412, textScale: scale, ocrRunning: true),
        );
        expect(tester.takeException(), isNull);
        expectChipClear(tester, fullText: scale == 1.0);
        expect(
          find.byKey(const ValueKey<String>('cancel_ocr')),
          findsOneWidget,
        );
        // 方向按钮被降进 ⋮：栏上没有，菜单里有、点得到。
        expect(find.byKey(const ValueKey<String>('direction')), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey<String>('manga_chrome_overflow')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Right to left'), findsOneWidget);
      });
    }

    testWidgets('极端字号（2.0）降完也放不下：胶囊省略收缩，仍不与按钮相交', (WidgetTester tester) async {
      await tester.pumpWidget(
        phoneHost(width: 360, textScale: 2.0, ocrRunning: true),
      );
      expect(tester.takeException(), isNull);
      final Rect chip = tester.getRect(
        find.byKey(const ValueKey<String>('manga_page_jump_button')),
      );
      for (final Element e
          in find
              .descendant(
                of: find.byType(MangaReaderTopBar),
                matching: find.byType(IconButton),
              )
              .evaluate()) {
        final Rect r = tester.getRect(find.byElementPredicate((x) => x == e));
        expect(chip.overlaps(r), isFalse);
      }
    });
  });

  group('planMangaTopBarActions', () {
    MangaChromeAction action(
      String id, {
      bool pinned = false,
      bool secondary = false,
    }) => MangaChromeAction(
      key: ValueKey<String>(id),
      icon: Icons.circle,
      label: id,
      pinned: pinned,
      secondary: secondary,
      onPressed: () {},
    );

    test('胶囊放得下时不降任何 pinned；放不下时从后往前降 secondary', () {
      final MangaChromeAction dir = action(
        'dir',
        pinned: true,
        secondary: true,
      );
      final MangaChromeAction start = action(
        'start',
        pinned: true,
        secondary: true,
      );
      final MangaChromeAction mode = action('mode');
      final MangaChromeAction settings = action('settings', pinned: true);
      final List<List<MangaChromeAction>> groups = <List<MangaChromeAction>>[
        <MangaChromeAction>[dir, start, mode],
        <MangaChromeAction>[settings],
      ];
      // 8 + (返回 + 章节 + dir + start + settings + ⋮) × 48 = 296。
      final MangaTopBarActionPlan roomy = planMangaTopBarActions(
        width: 412,
        leadingCount: 1,
        groups: groups,
        titleAreaMinWidth: 80,
      );
      expect(roomy.compact, isTrue);
      expect(roomy.inline, containsAll(<MangaChromeAction>[dir, start]));
      expect(roomy.overflow, <MangaChromeAction>[mode]);

      // 胶囊要 130：降 start 一颗（-48）就够。
      final MangaTopBarActionPlan tight = planMangaTopBarActions(
        width: 412,
        leadingCount: 1,
        groups: groups,
        titleAreaMinWidth: 130,
      );
      expect(tight.inline.contains(start), isFalse);
      expect(tight.inline.contains(dir), isTrue);
      expect(tight.overflow, <MangaChromeAction>[start, mode]);
      expect(tight.titleAreaWidth, greaterThanOrEqualTo(130));
    });

    test('宽窗未过阈值但按钮 + 胶囊放不下 → 也进紧凑形态', () {
      final List<MangaChromeAction> many = <MangaChromeAction>[
        for (int i = 0; i < 16; i++) action('a$i'),
      ];
      final MangaTopBarActionPlan plan = planMangaTopBarActions(
        width: kReaderDesktopHeaderCompactWidth + 40,
        leadingCount: 1,
        groups: <List<MangaChromeAction>>[many],
        titleAreaMinWidth: 80,
      );
      expect(plan.compact, isTrue);
      expect(plan.overflow, hasLength(16));
    });
  });
}
