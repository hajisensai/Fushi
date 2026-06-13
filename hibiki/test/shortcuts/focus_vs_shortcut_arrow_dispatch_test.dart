import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/utils/components/hibiki_focus_ring.dart';

/// BUG-263 — 焦点遍历与方向键快捷键互抢的根因修复回归测试。
///
/// 修复前 [wrapWithGlobalNavigation] 的方向键焦点处理只接管 OS 自动重复
/// ([KeyRepeatEvent])，**故意把按下边沿 ([KeyDownEvent]) 留给 Flutter
/// [WidgetsApp] 内建的 [DirectionalFocusAction]**。结果：在一个 Hibiki 受管控件
/// 上按住方向键，按下走框架朴素几何（无 Hibiki 的 reading-order / 面板 / 滚动
/// 兜底），重复走 Hibiki 几何——按下与重复分属两套焦点引擎，在边沿处按下卡住、
/// 紧接着的重复却能逃逸，即用户报的「焦点抢快捷键、左右总冲突」。
///
/// 根因修复：当 [focusNavigationEnabled] 开 + 焦点落在受管目标时，wrapper
/// 同时接管按下与重复，二者走同一 [gamepadMoveFocusInDirection] 并在按下时即
/// `KeyEventResult.handled` 消费——框架的 [DirectionalFocusAction] 再也拿不到
/// 方向键，只剩单一焦点引擎。
///
/// 测试策略（区分两套引擎的关键）：在 wrapper 之上放一个**哨兵 [Focus]** 记录
/// 它收到的方向键。键事件自焦点节点向上冒泡，wrapper 比哨兵更靠近焦点先处理；
/// 若 wrapper 在按下边沿 `handled`（修复后），方向键被消费、哨兵收不到；若
/// wrapper 在按下边沿 `ignored`（修复前），方向键继续上冒、哨兵收到——并最终
/// 落到框架 [DirectionalFocusAction]。哨兵计数因此直接证明「按下边沿归谁」。
void main() {
  /// 渲染：哨兵 Focus（记录上冒到此处的方向键 KeyDown）→ HibikiFocusRoot/Ring →
  /// wrapWithGlobalNavigation → 一列受管目标（无页级方向键处理器）。
  Future<
      ({
        HibikiFocusController controller,
        List<LogicalKeyboardKey> sentinel
      })> pump(
    WidgetTester tester,
    GlobalKey<NavigatorState> navKey, {
    required List<HibikiFocusId> ids,
    bool focusNavigationEnabled = true,
  }) async {
    late HibikiFocusController controller;
    final List<LogicalKeyboardKey> sentinel = <LogicalKeyboardKey>[];
    final FocusNode sentinelNode =
        FocusNode(debugLabel: 'sentinel', skipTraversal: true);
    addTearDown(sentinelNode.dispose);

    final List<Widget> targets = <Widget>[
      for (final HibikiFocusId id in ids)
        HibikiFocusTarget(
          id: id,
          child: const SizedBox(width: 120, height: 40),
        ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: Focus(
          focusNode: sentinelNode,
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (FocusNode node, KeyEvent event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.arrowDown ||
                    event.logicalKey == LogicalKeyboardKey.arrowUp ||
                    event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                    event.logicalKey == LogicalKeyboardKey.arrowRight)) {
              sentinel.add(event.logicalKey);
            }
            return KeyEventResult.ignored;
          },
          child: HibikiFocusRoot(
            child: HibikiFocusRing(
              child: wrapWithGlobalNavigation(
                navigatorKey: navKey,
                focusNavigationEnabled: focusNavigationEnabled,
                child: Builder(
                  builder: (BuildContext context) {
                    controller = HibikiFocusRoot.controllerOf(context);
                    // 无 Focus(onKeyEvent: ...) 页级处理器——按下边沿必须由
                    // wrapWithGlobalNavigation 接管才算修复（否则落框架）。
                    return Scaffold(body: Column(children: targets));
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller: controller, sentinel: sentinel);
  }

  const HibikiFocusId a = HibikiFocusId('a');
  const HibikiFocusId b = HibikiFocusId('b');
  const HibikiFocusId c = HibikiFocusId('c');

  testWidgets('BUG-263: 受管目标上方向键「按下」被 wrapper 消费，不再上冒到框架引擎',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final result = await pump(tester, navKey, ids: <HibikiFocusId>[a, b, c]);
    result.controller.requestById(a);
    await tester.pump();
    expect(result.controller.activeId, a);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    // 决定性断言：wrapper 在按下边沿消费了方向键，哨兵（其祖先）收不到——
    // 修复前 wrapper 在按下边沿 `ignored`，方向键上冒到哨兵 + 框架引擎。
    expect(result.sentinel, isEmpty,
        reason: '按下边沿必须被全局 wrapper 消费，不得上冒到框架 '
            'DirectionalFocusAction（修复前会上冒，哨兵收到）');
    expect(result.controller.activeId, b,
        reason: '按下经 wrapper 的 Hibiki 焦点引擎移焦一格');

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
  });

  testWidgets('BUG-263: 按下与重复走同一引擎，连续步进且都不上冒框架', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final result = await pump(tester, navKey, ids: <HibikiFocusId>[a, b, c]);
    result.controller.requestById(a);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(result.controller.activeId, b);

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(result.controller.activeId, c,
        reason: '重复经同一 wrapper 引擎继续移焦——与按下同源，不分裂');
    expect(result.sentinel, isEmpty, reason: '按下与重复都被 wrapper 消费，框架引擎从不介入');

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
  });

  testWidgets('BUG-263: 焦点导航关闭时 wrapper 不接管方向键，按下照常上冒（原生遍历兜底）',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final result = await pump(
      tester,
      navKey,
      ids: <HibikiFocusId>[a, b],
      focusNavigationEnabled: false,
    );
    result.controller.requestById(a);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    // 关闭时整块方向键分支不挂，wrapper 不消费——方向键照常上冒到哨兵/框架，
    // 回退到 Flutter 原生遍历（BUG-161/196 裁定：关态停自定义焦点导航）。
    expect(result.sentinel, contains(LogicalKeyboardKey.arrowDown),
        reason: '焦点导航关闭：wrapper 不消费方向键，按下边沿照常上冒');

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
  });
}
