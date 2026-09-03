import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/components/section_swipe_navigator.dart';

/// [SectionSwipeNavigator] 的行为守卫。
///
/// 口径说明：
///  * `tester.fling` / `startGesture` 默认就是触屏指针，正好落进组件的
///    supportedDevices；鼠标路径用显式 `kind: PointerDeviceKind.mouse` 验拒收。
///  * `tester.drag` 的事件时间戳挤在一起，速度估计为 0——用它验「低速长拖」。
///  * 级联用显式 physics（Clamping / Bouncing 各一），不依赖测试平台默认物理。
enum _S { a, b, c }

void main() {
  late List<_S> selections;

  setUp(() {
    selections = <_S>[];
  });

  Widget harness({
    _S selected = _S.b,
    TextDirection direction = TextDirection.ltr,
    Widget? child,
  }) {
    return MaterialApp(
      home: Directionality(
        textDirection: direction,
        child: SectionSwipeNavigator<_S>(
          sections: const <_S>[_S.a, _S.b, _S.c],
          selected: selected,
          onSelect: selections.add,
          child: child ?? const SizedBox.expand(),
        ),
      ),
    );
  }

  /// 定高横滚行；内容远小于视口，任何拖动都贴着边缘（最严苛的级联形状）。
  /// dragDevices 放开鼠标，镜像生产横滚行外面的 `HorizontalDragScrollable`——
  /// 否则「鼠标不级联」用例里鼠标压根拖不动行，断言空转。
  /// physics 必须带 AlwaysScrollable 外壳（同生产 `desktopAwareScrollPhysics`）：
  /// 裸 Clamping 在内容不满视口时 `shouldAcceptUserOffset` 为假、行拒收拖拽，
  /// 拖拽会掉进外层整页横滑——级联用例就测不到级联本身了。
  Widget row({required bool marked, required ScrollPhysics physics}) {
    final Widget list = SizedBox(
      height: 120,
      child: Builder(
        builder: (BuildContext context) => ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: const <PointerDeviceKind>{
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.stylus,
            },
          ),
          child: ListView(
            scrollDirection: Axis.horizontal,
            physics: physics,
            children: <Widget>[
              for (int i = 0; i < 3; i++)
                SizedBox(width: 60, child: Center(child: Text('卡$i'))),
            ],
          ),
        ),
      ),
    );
    return Center(child: marked ? SectionSwipeCascade(child: list) : list);
  }

  testWidgets('LTR 向左甩动切到右边的分区', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.flingFrom(const Offset(400, 300), const Offset(-260, 0), 1000);
    await tester.pumpAndSettle();
    expect(selections, <_S>[_S.c]);
  });

  testWidgets('LTR 向右甩动切到左边的分区', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.flingFrom(const Offset(400, 300), const Offset(260, 0), 1000);
    await tester.pumpAndSettle();
    expect(selections, <_S>[_S.a]);
  });

  testWidgets('端头不越界：末位继续向左甩无事发生', (WidgetTester tester) async {
    await tester.pumpWidget(harness(selected: _S.c));
    await tester.flingFrom(const Offset(400, 300), const Offset(-260, 0), 1000);
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
  });

  testWidgets('RTL 下物理方向反转：向左甩是回上一分区', (WidgetTester tester) async {
    await tester.pumpWidget(harness(direction: TextDirection.rtl));
    await tester.flingFrom(const Offset(400, 300), const Offset(-260, 0), 1000);
    await tester.pumpAndSettle();
    expect(selections, <_S>[_S.a]);
  });

  testWidgets('低速短拖不触发，低速长拖（过距离门）触发', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.dragFrom(const Offset(400, 300), const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(selections, isEmpty, reason: '60px < 距离门，且 tester.drag 速度≈0');

    await tester.dragFrom(const Offset(400, 300), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(selections, <_S>[_S.c]);
  });

  testWidgets('鼠标横拖不切区（滑动切区只属于触屏/触笔）', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    final TestGesture gesture = await tester.startGesture(
      const Offset(400, 300),
      kind: PointerDeviceKind.mouse,
    );
    for (int i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
  });

  testWidgets('级联（Clamping）：标记行滚到尾缘继续拖切到下一分区', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        child: row(
          marked: true,
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
        ),
      ),
    );
    await tester.dragFrom(
      tester.getCenter(find.text('卡1')), // 行内起手
      const Offset(-160, 0),
    );
    await tester.pumpAndSettle();
    expect(selections, <_S>[_S.c]);
  });

  testWidgets('级联（Clamping）：标记行贴着首缘向右拖回上一分区', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        child: row(
          marked: true,
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
        ),
      ),
    );
    await tester.dragFrom(
      tester.getCenter(find.text('卡1')),
      const Offset(160, 0),
    );
    await tester.pumpAndSettle();
    expect(selections, <_S>[_S.a]);
  });

  testWidgets('级联（Bouncing）：出界超过阈值即切区，一次拖拽只切一次', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        child: row(
          marked: true,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
        ),
      ),
    );
    await tester.dragFrom(
      tester.getCenter(find.text('卡1')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    expect(
      selections,
      <_S>[_S.c],
      reason:
          '橡皮筋越拖越沉，但阈值必须在一次长拖内可达；'
          '且 fired 位保证不会连环翻页',
    );
  });

  testWidgets('未标记的横向滚动区出界不切区（搜索框/页签条的保护形状）', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        child: row(
          marked: false,
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
        ),
      ),
    );
    await tester.dragFrom(
      tester.getCenter(find.text('卡1')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
  });

  testWidgets('级联同样只认触屏：鼠标把标记行拖过边缘不切区', (WidgetTester tester) async {
    await tester.pumpWidget(
      harness(
        child: row(
          marked: true,
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
        ),
      ),
    );
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('卡1')),
      kind: PointerDeviceKind.mouse,
    );
    for (int i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
  });
}
