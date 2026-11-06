import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_jump_history_controls.dart';

/// 漫画阅读器「跳转记录」的 chrome 接线：顶栏动作胶囊最前面的返回 / 前进图标、
/// 「⋯」里的面板入口、页码滑块上的落点刻度（所有者 2026-11-02 定稿）。
void main() {
  List<MangaChromeAction> topActions(int n) => <MangaChromeAction>[
    for (int i = 0; i < n; i++)
      MangaChromeAction(
        key: ValueKey<String>('a$i'),
        icon: Icons.star,
        label: 'action $i',
        slot: MangaChromeSlot.top,
        priority: 100 - i,
        onPressed: () {},
      ),
  ];

  Widget topHost({
    required double width,
    required List<FushiToolbarItem> jumpItems,
    List<MangaChromeAction> overflow = const <MangaChromeAction>[],
    int actionCount = 3,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            child: MangaReaderTopBar(
              title: '第38話',
              floating: true,
              backTooltip: 'back',
              onBack: () {},
              actions: topActions(actionCount),
              overflowActions: overflow,
              jumpItems: jumpItems,
            ),
          ),
        ),
      ),
    ),
  );

  group('顶栏跳转图标', () {
    testWidgets('排在动作胶囊最前面；点按返回 / 前进、长按开面板', (WidgetTester tester) async {
      int back = 0;
      int forward = 0;
      int panel = 0;
      await tester.pumpWidget(
        topHost(
          width: 1000,
          jumpItems: jumpHistoryToolbarItems(
            backLabel: '5 / 40',
            forwardLabel: '第42話 · 12 / 40',
            onBack: () => back++,
            onForward: () => forward++,
            onOpenPanel: () => panel++,
          ),
        ),
      );
      final Finder backBtn = find.byKey(
        const ValueKey<String>('fushi_jump_back'),
      );
      final Finder fwdBtn = find.byKey(
        const ValueKey<String>('fushi_jump_forward'),
      );
      expect(backBtn, findsOneWidget);
      expect(fwdBtn, findsOneWidget);
      final double backX = tester.getCenter(backBtn).dx;
      final double fwdX = tester.getCenter(fwdBtn).dx;
      final double firstActionX = tester
          .getCenter(find.byKey(const ValueKey<String>('a0')))
          .dx;
      expect(backX, lessThan(fwdX));
      expect(fwdX, lessThan(firstActionX));
      // 宽屏全部平铺：没有「⋯」。
      expect(
        find.byKey(const ValueKey<String>('manga_chrome_overflow')),
        findsNothing,
      );

      await tester.tap(backBtn);
      await tester.tap(fwdBtn);
      await tester.longPress(backBtn);
      await tester.pumpAndSettle();
      expect(back, 1);
      expect(forward, 1);
      expect(panel, 1);
    });

    testWidgets('最窄手机（360）上两颗跳转图标恒在，普通动作收进 ⋯', (WidgetTester tester) async {
      await tester.pumpWidget(
        topHost(
          width: 360,
          actionCount: 4,
          jumpItems: jumpHistoryToolbarItems(
            backLabel: '5 / 40',
            forwardLabel: '12 / 40',
            onBack: () {},
            onForward: () {},
            onOpenPanel: () {},
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('fushi_jump_back')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('fushi_jump_forward')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('manga_chrome_overflow')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有跳转图标时动作胶囊照旧', (WidgetTester tester) async {
      await tester.pumpWidget(
        topHost(width: 1000, jumpItems: const <FushiToolbarItem>[]),
      );
      expect(
        find.byKey(const ValueKey<String>('fushi_jump_back')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey<String>('a0')), findsOneWidget);
    });

    testWidgets('「⋯」里的「跳转记录」入口打开面板', (WidgetTester tester) async {
      int opened = 0;
      final FushiToolbarItem item = jumpHistoryPanelMenuItem(
        onOpen: () => opened++,
      );
      await tester.pumpWidget(
        topHost(
          width: 1000,
          jumpItems: const <FushiToolbarItem>[],
          overflow: <MangaChromeAction>[
            MangaChromeAction(
              key: item.key,
              icon: item.icon,
              label: item.label,
              slot: MangaChromeSlot.overflow,
              onPressed: item.onPressed,
            ),
          ],
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_chrome_overflow')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('fushi_jump_history_menu_menu_item')),
      );
      await tester.pumpAndSettle();
      expect(opened, 1);
    });
  });

  group('页码滑块刻度', () {
    Widget bottomHost(({List<double> back, List<double> forward})? marks) {
      final ValueNotifier<int> page = ValueNotifier<int>(4);
      return MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 400,
              child: MangaReaderBottomBar(
                pageCount: 40,
                pageListenable: page,
                currentPage: () => page.value,
                rtl: false,
                onPageCommitted: (_) {},
                jumpMarks: marks,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('有落点时叠在滑块轨道上、竖直居中、不吃指针', (WidgetTester tester) async {
      await tester.pumpWidget(
        bottomHost((back: <double>[0.25], forward: <double>[0.75])),
      );
      await tester.pumpAndSettle();
      final Finder marks = find.byKey(
        const ValueKey<String>('fushi_jump_progress_marks'),
      );
      expect(marks, findsOneWidget);
      final Rect slider = tester.getRect(
        find.byKey(const ValueKey<String>('manga_page_slider')),
      );
      final Rect markBox = tester.getRect(marks);
      expect(markBox.center.dy, moreOrLessEquals(slider.center.dy, epsilon: 1));
      expect(markBox.width, lessThan(slider.width));
      expect(
        find.ancestor(of: marks, matching: find.byType(IgnorePointer)),
        findsWidgets,
      );
    });

    testWidgets('无落点 / 关掉时不画', (WidgetTester tester) async {
      await tester.pumpWidget(bottomHost(null));
      expect(
        find.byKey(const ValueKey<String>('fushi_jump_progress_marks')),
        findsNothing,
      );
      await tester.pumpWidget(
        bottomHost((back: const <double>[], forward: const <double>[])),
      );
      expect(
        find.byKey(const ValueKey<String>('fushi_jump_progress_marks')),
        findsNothing,
      );
    });
  });
}
