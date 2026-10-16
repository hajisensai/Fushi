import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/fushi_m3e_misc_themes.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_scrollbar.dart';
import 'package:material_ui/material_ui.dart';

// 800×600 测试窗口、100 行 × 48 = 4800 高：拇指长 600 × 600 / 4800 = 75，
// 静息贴在顶端；横向占 [800 - 2 - 3, 800 - 2) = [795, 798)。
const double _rowHeight = 48;
const double _thumbLeft = 800 - 2 - kFushiScrollbarThickness;

/// 画布上有没有一条拇指宽度为 [width] 的圆角矩形。
PaintPattern _thumbOfWidth(double width) =>
    paints..something((Symbol method, List<dynamic> args) {
      if (method != #drawRRect) return false;
      final RRect rrect = args.first as RRect;
      return (rrect.width - width).abs() < 0.01;
    });

Widget _list(ScrollController controller, List<int> taps) {
  return ListView.builder(
    controller: controller,
    itemCount: 100,
    itemBuilder: (_, int i) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => taps.add(i),
      child: SizedBox(height: _rowHeight, child: Text('$i')),
    ),
  );
}

Widget _app(Widget body) {
  final ColorScheme cs = ColorScheme.fromSeed(seedColor: Colors.teal);
  return MaterialApp(
    scrollBehavior: const FushiScrollBehavior(),
    theme: ThemeData(
      colorScheme: cs,
      scrollbarTheme: fushiM3eScrollbarTheme(cs: cs, eink: false),
    ),
    home: Scaffold(body: body),
  );
}

void main() {
  final TargetPlatformVariant desktop = TargetPlatformVariant.only(
    TargetPlatform.windows,
  );

  late ScrollController controller;
  late List<int> taps;

  setUp(() {
    controller = ScrollController();
    taps = <int>[];
  });
  tearDown(() => controller.dispose());

  Finder scrollbars() =>
      find.byWidgetPredicate((Widget w) => w is RawScrollbar);

  testWidgets('auto scrollbar is the Fushi one, exactly one per list', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(_list(controller, taps)));
    await tester.pumpAndSettle();

    expect(scrollbars(), findsOneWidget);
    expect(find.byType(Scrollbar), findsNothing);
  }, variant: desktop);

  testWidgets('explicit FushiScrollbar does not stack on the auto one', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        FushiScrollbar(controller: controller, child: _list(controller, taps)),
      ),
    );
    await tester.pumpAndSettle();

    expect(scrollbars(), findsOneWidget);
  }, variant: desktop);

  testWidgets('hover never thickens the thumb', (WidgetTester tester) async {
    await tester.pumpWidget(_app(_list(controller, taps)));
    await tester.pumpAndSettle();
    final Finder bar = scrollbars();
    expect(bar, _thumbOfWidth(kFushiScrollbarThickness));

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(400, 300));
    await mouse.moveTo(const Offset(_thumbLeft + 1, 20));
    await tester.pumpAndSettle();

    expect(bar, _thumbOfWidth(kFushiScrollbarThickness));
  }, variant: desktop);

  testWidgets('pressing a few px beside the thin thumb still drags it', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(_list(controller, taps)));
    await tester.pumpAndSettle();

    // 拇指左侧 5px：原生只认画出来的 3px，这一下会落到列表上，往下拖反而把
    // 内容往回拉（偏移恒 0）。
    final TestGesture drag = await tester.startGesture(
      const Offset(_thumbLeft - 5, 20),
      kind: PointerDeviceKind.mouse,
    );
    for (int i = 0; i < 5; i++) {
      await drag.moveBy(const Offset(0, 10));
      await tester.pump();
    }
    await drag.up();
    await tester.pumpAndSettle();

    // 拇指移 50 → 内容移 50 × (4800 - 600) / (600 - 75) = 400。
    expect(controller.offset, closeTo(400, 1));
  }, variant: desktop);

  testWidgets('clicking the track neither pages nor eats the row under it '
      '(BUG-1997)', (WidgetTester tester) async {
    await tester.pumpWidget(_app(_list(controller, taps)));
    await tester.pumpAndSettle();

    // 拇指在顶端，点轨道中段：原生会整页翻一屏，且点击被滚动条吞掉。
    await tester.tapAt(
      const Offset(_thumbLeft + 1, 400),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(controller.offset, 0);
    expect(taps, <int>[400 ~/ _rowHeight]);
  }, variant: desktop);
}
