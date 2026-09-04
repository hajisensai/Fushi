import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';

import '../helpers/source_guard.dart';

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
    expect(currentScale(tester), isNull, reason: '系统开了「减弱动态效果」就不该有缩放层');
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
    expect(currentScale(tester), isNull, reason: '墨水屏上连续缩放会不断触发整屏重绘/残影');
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

  // BUG-2124 的压制位必须**自己**会落下，不能把落位挂在某条 build 分支上。
  //
  // 卡片正被悬停时来一次滚动 → 压制位置起；同一帧父级把 enabled 翻假（长按卡片进
  // 多选正好在指针停在卡上时发生）→ build 走 `!enabled` 的提前 return。落位若挂在
  // build 里，那次 post-frame 就永远注册不上，压制位永久为真：之后退出多选、鼠标
  // 重新移上来也**再不会抬升**，而且再来多少次滚动都只会在「已经是 true」处早退，
  // 永远没有那次重建去清它。
  testWidgets('滚动压制位在 enabled 翻假的那一帧也能落下', (WidgetTester tester) async {
    final ScrollController scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    late StateSetter setOuter;
    bool enabled = true;
    seenHover = <bool>[];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScrollNotificationObserver(
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setOuter = setState;
              return ListView(
                controller: scrollController,
                children: <Widget>[
                  FushiHoverLift(
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
                  const SizedBox(height: 2000),
                ],
              );
            },
          ),
        ),
      ),
    ));

    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.byKey(contentKey)));
    await tester.pumpAndSettle();
    expect(currentScale(tester), kFushiHoverLiftScale, reason: '前置：先抬起来');

    // 滚动置压制位，然后**在同一帧内**把 enabled 翻假。
    scrollController.jumpTo(10); // 滚一点点：卡不能被滚出视口，否则最后一次 hover 落在屏幕外
    setOuter(() => enabled = false);
    await tester.pumpAndSettle();
    expect(currentScale(tester), isNull, reason: '禁用时不建缩放层');

    // 退出多选、指针重新移上来：必须重新抬起来。
    setOuter(() => enabled = true);
    await tester.pumpAndSettle();
    // 先移开再移回：禁用期间壳没有 MouseRegion，光停在原地 MouseTracker 不会补发
    // enter，必须真发一次进入事件。
    await mouse.moveTo(const Offset(500, 500));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.byKey(contentKey)));
    await tester.pumpAndSettle();
    expect(
      currentScale(tester),
      kFushiHoverLiftScale,
      reason: '压制位没落下 → 之后永远不再抬升（整片卡的悬停放大失效）',
    );
  });

  // BUG-2124：压制位**不得**再靠 `ScrollStart..ScrollEnd` 那对通知。
  //
  // Flutter 不保证它们配对：`ScrollPosition.dispose()` 不调 `didEndScroll()`，
  // 而首页各 tab 的卡挂在同一个 Scaffold 的 observer 下、被 `TickerMode` 冻住的惯性
  // 滚动永远发不出 ScrollEnd。一个「Start 置真、只靠 End 落假」的位一旦命中，
  // 整片卡的悬停放大**永久**失效。这是删除类修复，行为测试造不出那个系统级时序，
  // 源码判据是最强可落地层。
  test('不得用 ScrollStart/ScrollEnd 当压制判据（它们不保证配对）', () {
    final String src = maskComments(
      File('lib/src/utils/components/fushi_hover_lift.dart').readAsStringSync(),
    );
    for (final String banned in <String>[
      'ScrollStartNotification',
      'ScrollEndNotification',
    ]) {
      expect(
        src.contains(banned),
        isFalse,
        reason: '$banned 不保证配对；压制只能认 ScrollUpdateNotification '
            '（它同时覆盖滚轮、拖拽与 FushiScrollController 的补间）',
      );
    }
    expect(
      src.contains('ScrollUpdateNotification'),
      isTrue,
      reason: '压制判据必须还在，否则滚动时悬停放大会残留在滚走的卡上',
    );
  });
}
