import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';

/// [FushiHoverLift] 是把游戏库那套「悬停放大 + 阴影加深」推广到书架 / 漫画 /
/// 视频库时抽出来的壳。原实现（`GalgamePosterCard` 内联）**没有**墨水屏与
/// 「减弱动态效果」两处降级——动效只在一个页面时问题不大，铺开到所有库页后
/// 就会明显劣化，所以这两条降级和 hover 本身一样要有守卫。
void main() {
  const Key contentKey = Key('lift-content');

  /// 记录 builder 每次拿到的 hover 态，用来分辨「没缩放」与「连 hover 都没有」。
  late List<bool> seenHover;

  Widget harness({
    bool enabled = true,
    bool disableAnimations = false,
    ThemeData? theme,
  }) {
    seenHover = <bool>[];
    return MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: FushiHoverLift(
              enabled: enabled,
              builder: (BuildContext context, bool hovering) {
                seenHover.add(hovering);
                return const ColoredBox(
                  key: contentKey,
                  color: Color(0xFF335577),
                  child: SizedBox(width: 80, height: 60),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<TestGesture> hoverOnto(WidgetTester tester) async {
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.byKey(contentKey)));
    await tester.pumpAndSettle();
    return mouse;
  }

  /// 当前**渲染**出来的缩放；壳没建缩放层时返回 null。
  ///
  /// BUG-2124 起缩放走显式 `AnimationController` + [Transform]（不再是
  /// `AnimatedScale`）：隐式动画即使时长为 0 也要晚两三帧才落值，滚动压制就压不
  /// 住。读渲染矩阵而不是目标值，缓动中间帧也算得准。
  double? currentScale(WidgetTester tester) {
    final Finder transforms = find.descendant(
      of: find.byType(FushiHoverLift),
      matching: find.byType(Transform),
    );
    if (transforms.evaluate().isEmpty) return null;
    return tester
        .widget<Transform>(transforms.first)
        .transform
        .getMaxScaleOnAxis();
  }

  testWidgets('鼠标移入放大到 kFushiHoverLiftScale，移出复位', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    expect(currentScale(tester), closeTo(1.0, 1e-6));

    final TestGesture mouse = await hoverOnto(tester);
    expect(currentScale(tester), closeTo(kFushiHoverLiftScale, 1e-6));
    expect(seenHover.last, isTrue, reason: 'builder 必须拿到 hover 态才能加深阴影');

    await mouse.moveTo(const Offset(500, 500));
    await tester.pumpAndSettle();
    expect(currentScale(tester), closeTo(1.0, 1e-6));
    expect(seenHover.last, isFalse);
  });

  testWidgets('减弱动态效果：不缩放，但 hover 态照常传给 builder', (WidgetTester tester) async {
    await tester.pumpWidget(harness(disableAnimations: true));
    await hoverOnto(tester);
    expect(currentScale(tester), isNull,
        reason: '系统开了「减弱动态效果」就不该有缩放层');
    expect(seenHover.last, isTrue, reason: '静态 hover 反馈（阴影/描边）必须保留，只去掉动效');
  });

  testWidgets('墨水屏：不缩放（持续缩放会不停刷屏），hover 态仍传给 builder',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(
      theme: ThemeData(
        extensions: const <ThemeExtension<dynamic>>[
          FushiEinkTheme(true),
        ],
      ),
    ));
    await hoverOnto(tester);
    expect(currentScale(tester), isNull,
        reason: '墨水屏上连续缩放会不断触发整屏重绘/残影');
    expect(seenHover.last, isTrue, reason: 'hover 反馈本身要留着（墨水屏上通常改成描边）');
  });

  testWidgets('enabled=false 时不建 MouseRegion，builder 恒拿到 false',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(enabled: false));
    expect(currentScale(tester), isNull);
    await hoverOnto(tester);
    expect(seenHover, everyElement(isFalse),
        reason: '禁用时不得有任何 hover 态泄漏给 builder');
  });
}
