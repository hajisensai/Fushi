import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/smooth_wheel_scroll.dart';

/// BUG-2834（接替 BUG-1960 / BUG-2009 的控制器守卫）：全 app 鼠标滚轮无极滚动。
///
/// 全仓只有根部 [SmoothWheelScrollScope] **一套**滚轮处理：它不挑控制器，普通
/// [ScrollController]、甚至没写控制器的 ListView（Scrollable 内部写死的
/// `ScrollController()`）都由它补间。别再给某个滚动区另起特制控制器拦
/// `pointerScroll`——两层同时在场就是两套阈值与策略。
///
/// 🔴 BUG-2009：只补插值、不改距离。每条距离断言都是 1:1。
void main() {
  final bool fineDeltaStaysNative = Platform.isWindows || Platform.isLinux;

  Widget scoped(Widget home) => MaterialApp(
    builder: (BuildContext context, Widget? child) =>
        SmoothWheelScrollScope(child: child!),
    home: home,
  );

  Widget buildList(ScrollController? controller) => scoped(
    ListView(
      controller: controller,
      children: const <Widget>[SizedBox(height: 30000)],
    ),
  );

  /// 发一次滚轮事件并只推进一帧。
  ///
  /// 🔴 **手势内的连续事件必须用这个，不能用 `pumpAndSettle`**：settle 会把假时钟
  /// 推过 200ms 的手势静默窗，每一次事件都成了「新手势」，「手势内锁定」测不到。
  Future<void> tick(WidgetTester tester, double delta) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: const Offset(20, 20),
        scrollDelta: Offset(0, delta),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }

  /// 判据按物理像素（BUG-2867）；测试视图默认 DPR 3.0。细 delta 用例把 DPR 设成 1，
  /// 让「12 逻辑 px」就是高精度滚轮 1/8 档的 12 物理 px。
  void atDevicePixelRatio(WidgetTester tester, double dpr) {
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('粗滚轮一档走满系统给的距离（120 → 120）', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 120);
    await tester.pumpAndSettle();

    expect(controller.offset, 120);
  });

  testWidgets('粗滚轮分帧到达，不是单帧瞬移', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    // tick 里那一帧只把 Ticker 起起来（首帧 elapsed 恒为 0），再推进 40ms 才落在
    // 动画中途。
    await tick(tester, 120);
    await tester.pump(const Duration(milliseconds: 40));

    expect(
      controller.offset,
      allOf(greaterThan(0.0), lessThan(120.0)),
      reason: '粗滚轮应在多帧内逐步到达目标（全平台，含 macOS）',
    );
    await tester.pumpAndSettle();
    expect(controller.offset, 120);
  });

  testWidgets('没写控制器的 ListView 一样补间（根部一处接住所有滚动区）', (WidgetTester tester) async {
    await tester.pumpWidget(buildList(null));
    final ScrollPosition position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;

    await tick(tester, 120);
    await tester.pump(const Duration(milliseconds: 40));
    expect(position.pixels, allOf(greaterThan(0.0), lessThan(120.0)));
    await tester.pumpAndSettle();
    expect(position.pixels, 120);
  });

  testWidgets('没有 SmoothWheelScrollScope 时是 Flutter 原生单帧跳（对照组）', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: controller,
          children: const <Widget>[SizedBox(height: 30000)],
        ),
      ),
    );

    await tick(tester, 120);
    expect(controller.offset, 120, reason: '对照组证明上面的补间来自本层');
  });

  testWidgets('连拨同向从未到达的目标累加，不吃距离', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 120);
    await tick(tester, 120);
    await tick(tester, 120);
    await tester.pumpAndSettle();

    expect(controller.offset, 360);
  });

  testWidgets('反拨从当前视觉位置起步', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));
    controller.jumpTo(1000);
    await tester.pump(const Duration(milliseconds: 400));

    await tick(tester, 120);
    await tester.pump(const Duration(milliseconds: 40));
    final double mid = controller.offset;
    expect(mid, allOf(greaterThan(1000.0), lessThan(1120.0)));
    await tick(tester, -120);
    await tester.pumpAndSettle();

    expect(controller.offset, closeTo(mid - 120, 0.001));
  });

  testWidgets('200% 缩放：Windows 默认一档只有 50 逻辑 px，照样补间（BUG-2867）', (
    WidgetTester tester,
  ) async {
    // Windows 引擎一档 = 行数 × 100/3 物理 px（默认 3 行 = 100），框架除以 DPR 2
    // 后只剩 50。旧判据「逻辑 px >= 80」把它当成触控板，补间从未生效。
    atDevicePixelRatio(tester, 2.0);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 50);
    await tester.pump(const Duration(milliseconds: 40));
    expect(
      controller.offset,
      allOf(greaterThan(0.0), lessThan(50.0)),
      reason: '高 DPI 下的粗滚轮也必须分帧到达',
    );
    await tester.pumpAndSettle();
    expect(controller.offset, 50, reason: '距离 1:1 不变（BUG-2009）');
  });

  testWidgets('200% 缩放 + 每次滚动 1 行：一档 16.5 逻辑 px 仍补间（BUG-2867）', (
    WidgetTester tester,
  ) async {
    atDevicePixelRatio(tester, 2.0);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 16.5); // 引擎 1 行 = int(33.3) = 33 物理 px
    await tester.pump(const Duration(milliseconds: 40));
    expect(controller.offset, allOf(greaterThan(0.0), lessThan(16.5)));
    await tester.pumpAndSettle();
    expect(controller.offset, 16.5);
  });

  testWidgets('200% 缩放下高精度滚轮 1/8 档仍同步 1:1（BUG-2867）', (
    WidgetTester tester,
  ) async {
    atDevicePixelRatio(tester, 2.0);
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 6.25); // 12.5 物理 px
    if (fineDeltaStaysNative) expect(controller.offset, 6.25);
    await tester.pumpAndSettle();
    expect(controller.offset, 6.25);
  });

  testWidgets('细 delta 开头的手势整段保持同步 1:1', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    atDevicePixelRatio(tester, 1.0);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 12);
    await tick(tester, 120);
    if (fineDeltaStaysNative) {
      expect(controller.offset, 132, reason: '细指针手势整段同步到位，无补间拖尾');
    }
    await tester.pumpAndSettle();
    expect(controller.offset, 132);
  });

  testWidgets('粗滚轮手势里的小尾帧不得走同步路径掐断动画', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    atDevicePixelRatio(tester, 1.0);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 120);
    await tester.pump(const Duration(milliseconds: 40));
    await tick(tester, 12);
    await tester.pumpAndSettle();

    expect(controller.offset, 132);
  });

  testWidgets('静默超过 200ms 后重新分类（滚轮之后换高精度设备）', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    atDevicePixelRatio(tester, 1.0);
    await tester.pumpWidget(buildList(controller));

    await tick(tester, 120);
    await tester.pumpAndSettle();
    expect(controller.offset, 120);
    await tester.pump(const Duration(milliseconds: 400));

    await tick(tester, 12);
    if (fineDeltaStaysNative) expect(controller.offset, 132);
    await tester.pumpAndSettle();
    expect(controller.offset, 132);
  });

  testWidgets('惯性取消立刻清掉分类且不丢已拨出的距离', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    atDevicePixelRatio(tester, 1.0);
    await tester.pumpWidget(buildList(controller));

    // 🔴 惯性取消是独立的 PointerScrollInertiaCancelEvent，不是 scrollDelta 0。
    await tick(tester, 120);
    await tester.pump(const Duration(milliseconds: 40)); // 动画还在飞
    await tester.sendEventToBinding(
      const PointerScrollInertiaCancelEvent(position: Offset(20, 20)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.offset, 120, reason: '取消停的是动画，不是已拨出去的距离');

    await tick(tester, 12);
    if (fineDeltaStaysNative) expect(controller.offset, 132);
    await tester.pumpAndSettle();
    expect(controller.offset, 132);
  });

  testWidgets('钳到可滚动范围内，不越界', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(buildList(controller));

    for (int i = 0; i < 400; i++) {
      await tick(tester, 120);
    }
    await tester.pumpAndSettle();

    expect(controller.offset, controller.position.maxScrollExtent);
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('PageView 等吸附式滚动保持原生（物理已接管）', (WidgetTester tester) async {
    final PageController controller = PageController();
    addTearDown(controller.dispose);
    final List<double> seen = <double>[];
    controller.addListener(() => seen.add(controller.offset));
    await tester.pumpWidget(
      scoped(
        PageView(
          controller: controller,
          children: const <Widget>[
            SizedBox.expand(),
            SizedBox.expand(),
            SizedBox.expand(),
          ],
        ),
      ),
    );

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: const Offset(20, 20),
        scrollDelta: const Offset(120, 0),
      ),
    );
    await tester.pumpAndSettle();
    // 本层不插手：吸附模拟从 Flutter 落点单调走向某一页；本层若插手会先拉回
    // 起点 0 再补间回去，序列就不再单调。
    expect(seen, isNotEmpty);
    final bool rising = seen.last >= seen.first;
    for (int i = 1; i < seen.length; i++) {
      expect(
        rising ? seen[i] >= seen[i - 1] : seen[i] <= seen[i - 1],
        isTrue,
        reason: 'offset 序列 $seen 不单调：吸附被本层拉回再补间',
      );
    }
  });

  testWidgets('裁决期间被联动的跟随者不被误动（只认指针下的滚动区）', (WidgetTester tester) async {
    final ScrollController leader = ScrollController();
    final ScrollController follower = ScrollController();
    addTearDown(leader.dispose);
    addTearDown(follower.dispose);
    leader.addListener(() {
      if (follower.hasClients) follower.jumpTo(leader.offset);
    });
    await tester.pumpWidget(
      scoped(
        Row(
          children: <Widget>[
            Expanded(
              child: ListView(
                controller: leader,
                children: const <Widget>[SizedBox(height: 30000)],
              ),
            ),
            Expanded(
              child: ListView(
                controller: follower,
                children: const <Widget>[SizedBox(height: 30000)],
              ),
            ),
          ],
        ),
      ),
    );

    await tick(tester, 120);
    await tester.pump(const Duration(milliseconds: 40));
    expect(leader.offset, allOf(greaterThan(0.0), lessThan(120.0)));
    expect(follower.offset, leader.offset, reason: '跟随者照常跟随领头者');
    await tester.pumpAndSettle();
    expect(leader.offset, 120);
    expect(follower.offset, 120);
  });

  test('主 app 与弹窗词典的根部都挂了本层', () {
    for (final String path in <String>[
      'lib/main.dart',
      'lib/popup_main.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('SmoothWheelScrollScope('),
        reason: '$path 的 MaterialApp builder 必须包 SmoothWheelScrollScope',
      );
    }
  });

  test('不得复活按控制器逐个接线的平行滚轮实现', () {
    for (final FileSystemEntity f in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final String src = f.readAsStringSync();
      expect(
        src.contains('class FushiScrollController') ||
            src.contains('void pointerScroll('),
        isFalse,
        reason: '${f.path}：滚轮平滑只在 SmoothWheelScrollScope 一处',
      );
    }
  });
}
