import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// BUG-1960 / BUG-2009 守卫：Windows 粗鼠标滚轮的「一格一大跳」。
///
/// 全仓只有 [FushiScrollController] **一套**桌面滚轮处理（BUG-1959 引入，BUG-1960
/// 把「手势内锁定设备分类」并了进去）。别再另起一个平行控制器：两套都拦
/// `pointerScroll`，同时在场就是两层处理，阈值和策略还要在两处各写一遍。
///
/// 🔴 BUG-2009：这套东西**只补插值、不改距离**。BUG-1960 首版额外把粗滚轮 delta
/// 减半并封顶 120px，用户实报「不掉帧了但是速度慢了」——一档走多远是系统「每次
/// 滚动行数」设置说了算。下面每条距离断言都是平台无关的 1:1，平台差异只体现在
/// 「这一段是分帧到达还是单帧到达」。
void main() {
  final bool animates = Platform.isWindows || Platform.isLinux;

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

  testWidgets('粗滚轮一档走满系统给的距离（120 → 120）', (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 120);
    await tester.pumpAndSettle();

    // 距离与平台无关：app 不打折。变异「乘 0.5」→ 60，红。
    expect(controller.offset, 120);
  });

  testWidgets('粗滚轮分帧到达，不是单帧瞬移', (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    // tick 里那一帧只把 Ticker 起起来（首帧 elapsed 恒为 0，位移还是 0），
    // 再推进 40ms 才落在动画中途。
    await tick(tester, 120);
    await tester.pump(const Duration(milliseconds: 40));

    if (animates) {
      expect(
        controller.offset,
        allOf(greaterThan(0.0), lessThan(120.0)),
        reason: '粗滚轮应在多帧内逐步到达目标，流畅由这段补间给，不由缩短距离给',
      );
    } else {
      expect(controller.offset, 120,
          reason: 'macOS/移动端保持平台原生 pointer delta，单帧到位');
    }
    await tester.pumpAndSettle();
    expect(controller.offset, 120);
  });

  testWidgets('细 delta 开头的手势整段保持同步 1:1', (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    // 首帧 12 判为细指针；紧接着的 120 仍属同一手势，不得改判成粗滚轮去加补间。
    await tick(tester, 12);
    await tick(tester, 120);
    expect(controller.offset, 132, reason: '细指针手势整段同步到位，无补间拖尾');
    await tester.pumpAndSettle();
    expect(controller.offset, 132);
  });

  testWidgets('粗滚轮手势里的小尾帧不得走同步路径掐断动画',
      (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    // 首帧 120 判为粗滚轮，动画在飞。尾帧 12 若按「本帧不够阈值就走同步」处理，
    // `pointerScroll` 会先 goIdle 掐掉飞行中的 DrivenScrollActivity 再 forcePixels，
    // 这一次拨动的距离就只剩「动画走到一半的位置 + 12」。
    await tick(tester, 120);
    await tester.pump(const Duration(milliseconds: 40));
    await tick(tester, 12);
    await tester.pumpAndSettle();

    expect(controller.offset, 132);
  });

  testWidgets('静默超过 200ms 后重新分类（滚轮之后换触控板）',
      (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 120);
    await tester.pumpAndSettle();
    expect(controller.offset, 120);
    await tester.pump(const Duration(milliseconds: 400)); // 手势结束

    // 新手势按细指针判：同步到位，一帧之内就是 132（仍挂着粗滚轮分类的话，
    // 这一帧只会走到 120 和 132 之间）。
    await tick(tester, 12);
    expect(controller.offset, 132);
  });

  testWidgets('delta 0（惯性取消）立刻清掉分类且不丢已拨出的距离',
      (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    // 🔴 惯性取消**不是** `PointerScrollEvent(scrollDelta: 0)`：Scrollable 的
    // `_receivedPointerSignal` 对零位移的 scroll 事件直接不派发（`delta != 0` 门），
    // 那种写法连 pointerScroll 都进不去、断言恒等于「没复位」。真实入口是独立的
    // `PointerScrollInertiaCancelEvent`，framework 收到后调 `pointerScroll(0)`。
    await tick(tester, 120);
    await tester.pump(const Duration(milliseconds: 40)); // 动画还在飞
    await tester.sendEventToBinding(
      const PointerScrollInertiaCancelEvent(position: Offset(20, 20)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    // 取消要停的是动画，不是已经拨出去的距离。
    expect(controller.offset, 120);

    // 三个事件都在同一个 200ms 窗内；没有这条复位，尾帧 12 会继承「粗滚轮」分类
    // 走补间，这一帧就到不了 132。
    await tick(tester, 12);
    expect(controller.offset, 132);
  });

  testWidgets('钳到可滚动范围内，不越界', (WidgetTester tester) async {
    final FushiScrollController controller = FushiScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    // 30000 高、600 视口 -> max 29400；一档 120px，留足余量确保真的滚到底。
    for (int i = 0; i < 400; i++) {
      await tick(tester, 120);
    }
    await tester.pumpAndSettle();

    expect(controller.offset, controller.position.maxScrollExtent);
    expect(controller.offset, greaterThan(0));
  });
}
