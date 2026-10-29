import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/video_continue_spotlight.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 视频首页「继续观看」首屏区（2026-10-28 方案 F）：剧照主卡 + 16:9 小卡；
/// 宽屏小卡是主卡旁的两行横滑网格、窄屏是主卡下的横滑行；这就是首页全部的
/// 继续观看（下面不再另起一行），所以小卡区必须能用鼠标横拖（用户实报「好像
/// 不能横向拖动」）。
void main() {
  final List<String> opened = <String>[];
  final List<String> menus = <String>[];

  VideoContinueSpotlightEntry entry(int i) => VideoContinueSpotlightEntry(
    cardKey: ValueKey<String>('spot-$i'),
    focusId: FushiFocusId('spot-$i'),
    title: 'Work $i',
    subtitle: 'Next · Episode ${i + 1} · 3 watched',
    shortSubtitle: 'Next · Episode ${i + 1}',
    image: ColoredBox(color: Color(0xFF203040 + i * 0x101010)),
    progress: 0.5,
    onOpen: () => opened.add('$i'),
    onLongPress: () => menus.add('$i'),
  );

  Widget harness(double width, int count) => MaterialApp(
    theme: ThemeData(
      extensions: const <ThemeExtension<dynamic>>[FushiEinkTheme(false)],
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: VideoContinueSpotlight(
              entries: <VideoContinueSpotlightEntry>[
                for (int i = 0; i < count; i++) entry(i),
              ],
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

  Future<void> pumpAt(WidgetTester tester, double width, int count) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(width, count));
    await tester.pumpAndSettle();
  }

  ScrollPosition sidePosition(WidgetTester tester, Type scrollView) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(scrollView),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  double gapUnit(WidgetTester tester) => FushiDesignTokens.of(
    tester.element(find.byType(VideoContinueSpotlight)),
  ).spacing.gap;

  testWidgets('宽屏：主卡旁是两行横滑网格，主卡高与骨架同一套几何', (WidgetTester tester) async {
    await pumpAt(tester, 1200, 15);
    expect(tester.takeException(), isNull);

    final Size main = tester.getSize(
      find.byKey(const ValueKey<String>('spot-0')),
    );
    expect(main.width / main.height, closeTo(16 / 9, 0.01));
    expect(
      main,
      VideoContinueSpotlight.placeholderMainSize(1200, gapUnit(tester)),
    );

    final GridView grid = tester.widget<GridView>(find.byType(GridView));
    expect(grid.scrollDirection, Axis.horizontal);
    // 小卡在主卡的行尾侧、与主卡顶对齐，两行。
    final Rect first = tester.getRect(
      find.byKey(const ValueKey<String>('spot-1')),
    );
    final Rect second = tester.getRect(
      find.byKey(const ValueKey<String>('spot-2')),
    );
    expect(first.left, greaterThan(main.width));
    expect(second.top, greaterThan(first.bottom));
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('宽屏：小卡网格能用鼠标横拖', (WidgetTester tester) async {
    await pumpAt(tester, 1200, 15);
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

  testWidgets('窄屏：主卡在上、小卡是下方横滑行，能用鼠标横拖', (WidgetTester tester) async {
    await pumpAt(tester, 400, 6);
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

  testWidgets('点按续播、长按出条目菜单（卡上没有按钮）', (WidgetTester tester) async {
    await pumpAt(tester, 1200, 3);
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

  testWidgets('小卡压完整的短副标题，不按分隔符切掉集数', (WidgetTester tester) async {
    await pumpAt(tester, 1200, 3);
    // 「下一集 · 第 N 集」按 ' · ' 切开只剩「下一集」，集数就丢了。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('spot-1')),
        matching: find.text('Next · Episode 2'),
      ),
      findsOneWidget,
    );
    // 主卡是完整副标题（含追加段）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('spot-0')),
        matching: find.text('Next · Episode 1 · 3 watched'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('只有一部在看时只画主卡，不出空的横滑区', (WidgetTester tester) async {
    for (final double width in <double>[1200, 400]) {
      await pumpAt(tester, width, 1);
      expect(find.byKey(const ValueKey<String>('spot-0')), findsOneWidget);
      expect(find.byType(GridView), findsNothing);
      expect(find.byType(ListView), findsNothing);
    }
  });
}
