import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// BUG-1960 守卫：Windows 粗鼠标滚轮的「一格一大跳」。
///
/// 全仓只有 [FushiScrollController] **一套**桌面滚轮细化实现（BUG-1959 引入，
/// 本 bug 把「手势内锁定设备分类」并了进去）。别再另起一个平行控制器：两套都拦
/// `pointerScroll`，同时在场就是两层折扣，而且阈值/倍率/要不要动画会在两处各写一遍。
///
/// 缩放只在 Windows/Linux 生效（macOS 的滚轮/触控板由系统给连续 delta，不该动），
/// 所以本文件的数值断言按宿主平台分流。
void main() {
  final bool scales = Platform.isWindows || Platform.isLinux;

  Widget buildList(ScrollController controller) {
    return MaterialApp(
      home: ListView(
        controller: controller,
        children: const <Widget>[SizedBox(height: 30000)],
      ),
    );
  }

  /// 发一次滚轮事件并只推进一帧。
  ///
  /// 🔴 **手势内的连续事件必须用这个，不能用 `pumpAndSettle`**：settle 会把假时钟
  /// 推过 200ms 的手势静默窗，于是每一次事件都成了「新手势」、分类被重新判定，
  /// 「手势内锁定」这条行为就永远测不到（写成 settle 时本文件两条断言恒假）。
  Future<void> tick(WidgetTester tester, double delta) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: const Offset(20, 20),
        scrollDelta: Offset(0, delta),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }

  testWidgets('粗滚轮一档减半（120 → 60）', (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 120);
    await tester.pumpAndSettle();

    expect(controller.offset, scales ? 60 : 120);
  });

  testWidgets('细 delta 开头的手势整段保持 1:1', (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    // 首帧 12 判为细指针；紧接着的 120 仍属同一手势，不得突然改按粗滚轮减半。
    await tick(tester, 12);
    await tick(tester, 120);
    await tester.pumpAndSettle();

    expect(controller.offset, 132);
  });

  testWidgets('粗滚轮手势里的小尾帧也照粗滚轮缩放', (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    // 首帧 120 判为粗滚轮；尾帧 12 若按 1:1 走，同一次拨动就成了「前段减半、尾段
    // 全量」，总距离对不上手感 —— 60 + 12 = 72 是**错**的，应当是 60 + 6 = 66。
    await tick(tester, 120);
    await tick(tester, 12);
    await tester.pumpAndSettle();

    expect(controller.offset, scales ? 66 : 132);
  });

  testWidgets('静默超过 200ms 后重新分类（滚轮之后换触控板）',
      (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 120); // 粗滚轮：60
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400)); // 手势结束
    await tick(tester, 12); // 新手势，细指针：1:1
    await tester.pumpAndSettle();

    expect(controller.offset, scales ? 72 : 132);
  });

  testWidgets('delta 0（惯性取消）立刻清掉分类', (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    // 三个事件都在同一个 200ms 窗内。没有惯性取消这条复位，尾帧 12 会继承
    // 「粗滚轮」分类被减半成 6（总 66）；有复位才是重新判定为细指针的 12（总 72）。
    //
    // 🔴 惯性取消**不是** `PointerScrollEvent(scrollDelta: 0)`：Scrollable 的
    // `_receivedPointerSignal` 对零位移的 scroll 事件直接不派发（`delta != 0` 门），
    // 那种写法连 pointerScroll 都进不去、断言恒等于「没复位」。真实入口是独立的
    // `PointerScrollInertiaCancelEvent`，framework 收到后调 `pointerScroll(0)`。
    await tick(tester, 120);
    await tester.sendEventToBinding(
      const PointerScrollInertiaCancelEvent(position: Offset(20, 20)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tick(tester, 12);
    await tester.pumpAndSettle();

    expect(controller.offset, scales ? 72 : 132);
  });

  testWidgets('钳到可滚动范围内，不越界', (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    // 30000 高、600 视口 -> max 29400；一档 60px，留足余量确保真的滚到底。
    for (int i = 0; i < 700; i++) {
      await tick(tester, 120);
    }
    await tester.pumpAndSettle();

    expect(controller.offset, controller.position.maxScrollExtent);
    expect(controller.offset, greaterThan(0));
  });
}
