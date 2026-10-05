import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';

/// 库页 M3E 浮动工具栏的共享件：滚动驱动显隐、弹簧收起、悬浮动作组的上下文切换。
void main() {
  ScrollUpdateNotification update(
    BuildContext context, {
    required double pixels,
    required double delta,
    Axis axis = Axis.vertical,
  }) {
    return ScrollUpdateNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 5000,
        pixels: pixels,
        viewportDimension: 600,
        axisDirection: axis == Axis.vertical
            ? AxisDirection.down
            : AxisDirection.right,
        devicePixelRatio: 1,
      ),
      context: context,
      scrollDelta: delta,
    );
  }

  testWidgets('下行累计越过阈值才收起，上行越过阈值或回顶弹回；横滚不算', (WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      Builder(
        builder: (BuildContext context) {
          ctx = context;
          return const SizedBox();
        },
      ),
    );
    final FushiFloatingChromeController controller =
        FushiFloatingChromeController();
    addTearDown(controller.dispose);

    // 首屏（离顶不足）下滚不收：用户还看得见页头。
    controller.handleScrollNotification(update(ctx, pixels: 30, delta: 30));
    expect(controller.visible, isTrue);
    // 一次手势结束，累计清零。
    controller.handleScrollNotification(
      ScrollEndNotification(
        metrics: update(ctx, pixels: 30, delta: 0).metrics,
        context: ctx,
      ),
    );

    // 微抖不收。
    controller.handleScrollNotification(update(ctx, pixels: 200, delta: 10));
    expect(controller.visible, isTrue);
    controller.handleScrollNotification(update(ctx, pixels: 220, delta: 20));
    expect(controller.visible, isFalse, reason: '同向累计 30 > 24 且已离顶');

    // 横滚卡片行的通知不影响显隐。
    controller.handleScrollNotification(
      update(ctx, pixels: 100, delta: -200, axis: Axis.horizontal),
    );
    expect(controller.visible, isFalse);

    controller.handleScrollNotification(update(ctx, pixels: 210, delta: -10));
    expect(controller.visible, isFalse, reason: '反向微抖不弹回');
    controller.handleScrollNotification(update(ctx, pixels: 180, delta: -30));
    expect(controller.visible, isTrue);

    controller.hide();
    controller.handleScrollNotification(update(ctx, pixels: 0, delta: -5));
    expect(controller.visible, isTrue, reason: '回到顶部立刻弹回');
  });

  testWidgets('FushiSpringReveal：收起后零高度、不接指针；maintainState=false 时卸掉子树', (
    WidgetTester tester,
  ) async {
    Widget build({required bool visible, bool maintainState = true}) =>
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                FushiSpringReveal(
                  visible: visible,
                  maintainState: maintainState,
                  child: const SizedBox(
                    key: ValueKey<String>('probe'),
                    height: 56,
                    width: 200,
                  ),
                ),
              ],
            ),
          ),
        );

    await tester.pumpWidget(build(visible: true));
    expect(tester.getSize(find.byType(FushiSpringReveal)).height, 56);

    await tester.pumpWidget(build(visible: false));
    await tester.pump(const Duration(milliseconds: 16));
    final double midway = tester.getSize(find.byType(FushiSpringReveal)).height;
    expect(midway, lessThan(56), reason: '弹簧收起中，高度在过渡');
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(FushiSpringReveal)).height, 0);
    expect(
      find.byKey(const ValueKey<String>('probe')),
      findsOneWidget,
      reason: '默认保活：State 与焦点注册不随收起丢失',
    );

    await tester.pumpWidget(build(visible: true));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(FushiSpringReveal)).height, 56);

    await tester.pumpWidget(build(visible: false, maintainState: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('probe')), findsNothing);
  });

  testWidgets('焦点走进收起的工具区时立刻弹回', (WidgetTester tester) async {
    final FushiFloatingChromeController controller =
        FushiFloatingChromeController(visible: false);
    addTearDown(controller.dispose);
    final FocusNode node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FushiFloatingChromeScope(
            controller: controller,
            child: Column(
              children: <Widget>[
                FushiFloatingChromeReveal(
                  child: Focus(
                    focusNode: node,
                    child: const SizedBox(height: 48, width: 100),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(controller.visible, isFalse);
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(controller.visible, isTrue);
    expect(tester.getSize(find.byType(FushiSpringReveal)).height, 48);
  });

  testWidgets('悬浮动作组画出登记的页头动作，动作集合变了做交叉切换', (WidgetTester tester) async {
    final FushiShellActionsSlot slot = FushiShellActionsSlot();
    addTearDown(slot.dispose);
    final ValueNotifier<bool> selecting = ValueNotifier<bool>(false);
    addTearDown(selecting.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FushiShellTitleScope(
            title: 'Video',
            actionsSlot: slot,
            child: Column(
              children: <Widget>[
                Align(
                  alignment: Alignment.centerRight,
                  child: FushiFloatingActionsPill(slot: slot),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: selecting,
                  builder: (BuildContext context, bool value, Widget? _) =>
                      FushiPageHeader.customTitle(
                        title: const SizedBox.shrink(),
                        actions: value
                            ? <Widget>[
                                FushiIconButton(
                                  key: const ValueKey<String>('exit'),
                                  tooltip: 'exit',
                                  icon: Icons.close,
                                  onTap: () => selecting.value = false,
                                ),
                              ]
                            : <Widget>[
                                FushiIconButton(
                                  key: const ValueKey<String>('refresh'),
                                  tooltip: 'refresh',
                                  icon: Icons.refresh,
                                  onTap: () {},
                                ),
                                FushiIconButton(
                                  key: const ValueKey<String>('collections'),
                                  tooltip: 'collections',
                                  icon: Icons.collections_bookmark_outlined,
                                  onTap: () {},
                                ),
                              ],
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder pill = find.byType(FushiFloatingActionsPill);
    expect(
      find.descendant(
        of: pill,
        matching: find.byKey(const ValueKey<String>('refresh')),
      ),
      findsOneWidget,
      reason: '页头动作登记进槽、由悬浮动作组画出',
    );
    expect(
      find.descendant(of: pill, matching: find.byType(FushiFloatingPill)),
      findsOneWidget,
    );

    selecting.value = true;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      find.descendant(
        of: pill,
        matching: find.byKey(const ValueKey<String>('refresh')),
      ),
      findsOneWidget,
      reason: '切换途中旧组还在淡出（交叉切换，不是硬切）',
    );
    expect(
      find.descendant(
        of: pill,
        matching: find.byKey(const ValueKey<String>('exit')),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('refresh')), findsNothing);
    expect(find.byKey(const ValueKey<String>('exit')), findsOneWidget);
  });
}
