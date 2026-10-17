import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_chrome.dart';

Widget _host({
  required int pageCount,
  required ValueNotifier<int> page,
  required bool rtl,
  required ValueChanged<int> onCommitted,
  VoidCallback? onPageTap,
  String Function(int)? bubbleLabel,
}) {
  return MaterialApp(
    home: Scaffold(
      body: MangaReaderBottomBar(
        pageCount: pageCount,
        pageListenable: page,
        currentPage: () => page.value,
        rtl: rtl,
        onPageCommitted: onCommitted,
        onPageTap: onPageTap,
        bubbleLabel: bubbleLabel,
      ),
    ),
  );
}

void main() {
  group('slider 位置 ↔ 页号（纯函数）', () {
    test('LTR：位置就是页号', () {
      expect(mangaSliderPosition(pageIndex: 0, pageCount: 40, rtl: false), 0);
      expect(mangaSliderPosition(pageIndex: 39, pageCount: 40, rtl: false), 39);
    });

    test('RTL：镜像，第 1 页在物理右端', () {
      expect(mangaSliderPosition(pageIndex: 0, pageCount: 40, rtl: true), 39);
      expect(mangaSliderPosition(pageIndex: 39, pageCount: 40, rtl: true), 0);
    });

    test('两个方向都往返无损', () {
      for (final bool rtl in <bool>[false, true]) {
        for (int i = 0; i < 40; i++) {
          final double pos = mangaSliderPosition(
            pageIndex: i,
            pageCount: 40,
            rtl: rtl,
          );
          expect(
            mangaSliderPageIndex(position: pos, pageCount: 40, rtl: rtl),
            i,
            reason: 'rtl=$rtl 第 $i 页往返必须回到原页',
          );
        }
      }
    });

    test('越界页号被钳住，不抛也不算出负页', () {
      expect(mangaSliderPosition(pageIndex: -5, pageCount: 10, rtl: false), 0);
      expect(mangaSliderPosition(pageIndex: 99, pageCount: 10, rtl: false), 9);
      expect(mangaSliderPageIndex(position: -3, pageCount: 10, rtl: false), 0);
      expect(mangaSliderPageIndex(position: 99, pageCount: 10, rtl: false), 9);
    });

    test('单页 / 空书不产生位置', () {
      expect(mangaSliderPosition(pageIndex: 0, pageCount: 1, rtl: false), 0);
      expect(mangaSliderPosition(pageIndex: 0, pageCount: 0, rtl: true), 0);
      expect(mangaSliderPageIndex(position: 5, pageCount: 1, rtl: false), 0);
    });
  });

  group('底栏让位（纯函数）', () {
    test('悬浮态 / 界面隐藏 / 没有正文都不让位', () {
      expect(
        mangaChromeBottomInset(
          floating: true,
          chromeVisible: true,
          contentReady: true,
          gestureInset: 24,
        ),
        0,
      );
      expect(
        mangaChromeBottomInset(
          floating: false,
          chromeVisible: false,
          contentReady: true,
          gestureInset: 24,
        ),
        0,
      );
      expect(
        mangaChromeBottomInset(
          floating: false,
          chromeVisible: true,
          contentReady: false,
          gestureInset: 24,
        ),
        0,
      );
    });

    test('固定态让位 = 手势区 + 栏高（与画出的高度同源）', () {
      expect(
        mangaChromeBottomInset(
          floating: false,
          chromeVisible: true,
          contentReady: true,
          gestureInset: 24,
        ),
        24 + kMangaChromeBottomBarHeight,
      );
    });
  });

  group('MangaReaderBottomBar', () {
    testWidgets('单页书整条栏不画（没有可跳的页）', (WidgetTester tester) async {
      final ValueNotifier<int> page = ValueNotifier<int>(0);
      addTearDown(page.dispose);
      await tester.pumpWidget(
        _host(pageCount: 1, page: page, rtl: false, onCommitted: (_) {}),
      );
      expect(
        find.byKey(const ValueKey<String>('manga_page_slider')),
        findsNothing,
      );
    });

    testWidgets('读数显示当前页与总页数', (WidgetTester tester) async {
      final ValueNotifier<int> page = ValueNotifier<int>(2);
      addTearDown(page.dispose);
      await tester.pumpWidget(
        _host(pageCount: 40, page: page, rtl: false, onCommitted: (_) {}),
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('manga_slider_current_page')),
            )
            .data,
        '3',
        reason: '读数是 1-based',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('manga_slider_page_count')),
            )
            .data,
        '40',
      );
    });

    testWidgets('翻页时只重画本栏读数（不靠外部 setState）', (WidgetTester tester) async {
      final ValueNotifier<int> page = ValueNotifier<int>(0);
      addTearDown(page.dispose);
      await tester.pumpWidget(
        _host(pageCount: 40, page: page, rtl: false, onCommitted: (_) {}),
      );
      page.value = 10;
      await tester.pump();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('manga_slider_current_page')),
            )
            .data,
        '11',
      );
    });

    testWidgets('拖动中不跳页，松手才提交一次', (WidgetTester tester) async {
      final ValueNotifier<int> page = ValueNotifier<int>(0);
      addTearDown(page.dispose);
      final List<int> committed = <int>[];
      await tester.pumpWidget(
        _host(
          pageCount: 41,
          page: page,
          rtl: false,
          onCommitted: committed.add,
        ),
      );
      final Finder slider = find.byKey(
        const ValueKey<String>('manga_page_slider'),
      );
      final Offset center = tester.getCenter(slider);
      final TestGesture gesture = await tester.startGesture(center);
      await tester.pump();
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(committed, isEmpty, reason: '拖动中跳页会让每一格都触发一次窗口文档重建');
      await gesture.up();
      await tester.pump();
      expect(committed.length, 1, reason: '松手只提交一次');
      expect(committed.single, greaterThan(0));
    });

    testWidgets('RTL：把滑块推向物理左端 = 往后翻（页号变大）', (WidgetTester tester) async {
      final ValueNotifier<int> page = ValueNotifier<int>(0);
      addTearDown(page.dispose);
      final List<int> committed = <int>[];
      await tester.pumpWidget(
        _host(pageCount: 41, page: page, rtl: true, onCommitted: committed.add),
      );
      final Finder slider = find.byKey(
        const ValueKey<String>('manga_page_slider'),
      );
      // RTL 下第 1 页在物理右端，滑块起点也在右端；往左拖应前进。
      final Offset center = tester.getCenter(slider);
      final TestGesture gesture = await tester.startGesture(center);
      await tester.pump();
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(committed.single, greaterThan(20), reason: 'RTL 下往物理左拖必须走向卷尾');
    });

    testWidgets('拖动中气泡显示「页 / 总页」，松手气泡消失', (WidgetTester tester) async {
      final ValueNotifier<int> page = ValueNotifier<int>(0);
      addTearDown(page.dispose);
      await tester.pumpWidget(
        _host(pageCount: 41, page: page, rtl: false, onCommitted: (_) {}),
      );
      final Finder slider = find.byKey(
        const ValueKey<String>('manga_page_slider'),
      );
      expect(
        find.byKey(const ValueKey<String>('manga_slider_bubble')),
        findsNothing,
      );
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(slider),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(1, 0));
      await tester.pumpAndSettle();
      final String bubble = tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('manga_slider_bubble_text')),
          )
          .data!;
      final String readout = tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('manga_slider_current_page')),
          )
          .data!;
      expect(bubble, '$readout / 41', reason: '气泡与读数同一页');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('manga_slider_bubble')),
        findsNothing,
      );
    });

    testWidgets('双页模式：气泡文案由页面给跨页区间', (WidgetTester tester) async {
      final ValueNotifier<int> page = ValueNotifier<int>(0);
      addTearDown(page.dispose);
      await tester.pumpWidget(
        _host(
          pageCount: 41,
          page: page,
          rtl: true,
          onCommitted: (_) {},
          bubbleLabel: (int i) => 'pair ${i + 1}',
        ),
      );
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey<String>('manga_page_slider')),
        ),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('manga_slider_bubble_text')),
            )
            .data,
        startsWith('pair '),
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('点当前页读数 = 跳页入口', (WidgetTester tester) async {
      final ValueNotifier<int> page = ValueNotifier<int>(3);
      addTearDown(page.dispose);
      int taps = 0;
      await tester.pumpWidget(
        _host(
          pageCount: 40,
          page: page,
          rtl: false,
          onCommitted: (_) {},
          onPageTap: () => taps++,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_page_jump_button')),
      );
      expect(taps, 1);
    });
  });

  group('MangaHiddenPageBadge', () {
    testWidgets('画出页码且不吃指针', (WidgetTester tester) async {
      final ValueNotifier<int> page = ValueNotifier<int>(4);
      addTearDown(page.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MangaHiddenPageBadge(
              pageListenable: page,
              label: () => '${page.value + 1} / 40',
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('manga_hidden_page_badge')),
            )
            .data,
        '5 / 40',
      );
      // 全出血阅读时角标不得抢走点击（点击是翻页/查词/唤出界面的唯一通道）。
      // 只看组件自己的子树：MaterialApp 本身也带 IgnorePointer，按祖先找会恒真。
      expect(
        find.descendant(
          of: find.byType(MangaHiddenPageBadge),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
      );
    });

    testWidgets('label 返回 null 时不画', (WidgetTester tester) async {
      final ValueNotifier<int> page = ValueNotifier<int>(0);
      addTearDown(page.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MangaHiddenPageBadge(pageListenable: page, label: () => null),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('manga_hidden_page_badge')),
        findsNothing,
      );
    });
  });
}
