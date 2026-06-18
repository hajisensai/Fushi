import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用真实焦点系统驱动 UI，只发 in-engine 合成按键（绝不 tester.tap 坐标点击）。
///
/// `sendKeyEvent` 是驱动 Flutter 焦点的唯一可靠方式（见
/// integration_test/gamepad_navigation_test.dart），且不要求 OS 窗口真获得焦点
/// —— 这是桌面离屏/后台运行能成立的根因。
class FocusDriver {
  FocusDriver(this.tester);

  final WidgetTester tester;

  /// 有界 pump：live UI 可能有永不 settle 的动画，禁止 pumpAndSettle。
  static const Duration _settle = Duration(milliseconds: 250);

  FocusNode? get focused => FocusManager.instance.primaryFocus;

  Future<void> _key(LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump(_settle);
  }

  /// 用 Tab 遍历当前页，返回去重后的可达焦点序列（回到起点即停）。
  Future<List<FocusNode>> reachAll({int maxSteps = 80}) async {
    final List<FocusNode> order = <FocusNode>[];
    final Set<FocusNode> seen = <FocusNode>{};
    final FocusNode? start = focused;
    if (start != null) {
      order.add(start);
      seen.add(start);
    }
    for (int i = 0; i < maxSteps; i++) {
      await _key(LogicalKeyboardKey.tab);
      final FocusNode? f = focused;
      if (f == null) continue;
      if (seen.contains(f)) {
        if (order.isNotEmpty && f == order.first) break; // 转回起点 = 遍历完
        continue;
      }
      seen.add(f);
      order.add(f);
    }
    return order;
  }

  /// 反复发 [key] 直到 [reached] 为真或步数耗尽。
  Future<bool> focusUntil(
    bool Function() reached, {
    int maxSteps = 80,
    LogicalKeyboardKey key = LogicalKeyboardKey.tab,
  }) async {
    if (reached()) return true;
    for (int i = 0; i < maxSteps; i++) {
      await _key(key);
      if (reached()) return true;
    }
    return false;
  }

  /// 把焦点移到 [target] 子树内（不可达 = 真 bug）。
  Future<bool> focusWidget(Finder target, {int maxSteps = 80}) {
    return focusUntil(() => _focusOwns(target), maxSteps: maxSteps);
  }

  /// Requests a concrete [Focus] node attached to [target].
  ///
  /// This is a fallback for custom app focus targets whose owning node may be
  /// registered after the widget appears. It still keeps the interaction rooted
  /// in focus, without coordinate taps.
  Future<bool> requestFocusInside(
    Finder target, {
    String? debugLabelContains,
  }) async {
    if (target.evaluate().isEmpty) return false;
    final Finder focusFinder = find.descendant(
      of: target,
      matching: find.byType(Focus),
    );
    for (final Element element in focusFinder.evaluate()) {
      final Widget widget = element.widget;
      if (widget is! Focus) continue;
      final FocusNode? node = widget.focusNode;
      if (node == null) continue;
      final String label = node.debugLabel ?? '';
      if (debugLabelContains != null && !label.contains(debugLabelContains)) {
        continue;
      }
      if (await _requestFocusNode(node)) return true;
    }
    for (final Element targetElement in target.evaluate()) {
      bool found = false;
      targetElement.visitAncestorElements((Element ancestor) {
        final Widget widget = ancestor.widget;
        if (widget is! Focus) return true;
        final FocusNode? node = widget.focusNode;
        if (node == null) return true;
        final String label = node.debugLabel ?? '';
        if (debugLabelContains != null && !label.contains(debugLabelContains)) {
          return true;
        }
        node.requestFocus();
        found = true;
        return false;
      });
      if (found) {
        await tester.pump(_settle);
        final String? label = focused?.debugLabel;
        if (debugLabelContains == null ||
            (label?.contains(debugLabelContains) ?? false)) {
          return true;
        }
      }
    }
    return false;
  }

  Future<bool> _requestFocusNode(FocusNode node) async {
    node.requestFocus();
    await tester.pump(_settle);
    return focused == node;
  }

  bool _focusOwns(Finder target) {
    final FocusNode? f = focused;
    if (f == null) return false;
    // 焦点 scope 是容器，不代表任何具体控件被聚焦（例如路由根 ModalScope）。
    // 只有真正落在可聚焦控件上的普通 FocusNode 才算「拥有」某个 target —— 否则
    // scope 是所有 target 的共同祖先，反向子树判定会对全部 target 误报为命中。
    if (f is FocusScopeNode) return false;
    final BuildContext? ctx = f.context;
    if (ctx == null || target.evaluate().isEmpty) return false;
    final Element targetEl = target.evaluate().first;
    if (ctx == targetEl) return true;
    // 正向：焦点 owner 在 target 子树内（target 是可聚焦祖先，焦点落在其内部，
    // 例如 target=TextButton、焦点是它内层的 Focus）。
    bool focusInsideTarget = false;
    ctx.visitAncestorElements((Element el) {
      if (el == targetEl) {
        focusInsideTarget = true;
        return false;
      }
      return true;
    });
    if (focusInsideTarget) return true;
    // 反向：target 在焦点 owner 子树内（焦点挂在可聚焦祖先如 TextButton 的
    // Focus 上，而 target 是更里层的 Text）。此处 scope 已被上面排除，不会误报。
    bool targetInsideFocus = false;
    targetEl.visitAncestorElements((Element el) {
      if (el == ctx) {
        targetInsideFocus = true;
        return false;
      }
      return true;
    });
    return targetInsideFocus;
  }

  /// 激活当前焦点控件（Switch/按钮）。确认键统一用 Enter——App 已把裸空格中和为
  /// DoNothingIntent（焦点确认不走空格，见 global_navigation.dart），手柄 A 同义。
  Future<void> activate() => _key(LogicalKeyboardKey.enter);

  /// Invoke the standard Flutter activation intent for the current focus.
  ///
  /// Use this when a platform test runner cannot synthesize the desired
  /// physical confirm key, but the app has already moved focus to the target
  /// through [focusWidget].
  Future<bool> activateIntent() async {
    final BuildContext? ctx = focused?.context;
    if (ctx == null) return false;
    const ActivateIntent intent = ActivateIntent();
    final Action<ActivateIntent>? action =
        Actions.maybeFind<ActivateIntent>(ctx, intent: intent);
    if (action == null || !action.isEnabled(intent)) return false;
    Actions.invoke<ActivateIntent>(ctx, intent);
    await tester.pump(_settle);
    return true;
  }

  /// 对当前焦点控件用方向键加/减 N 步（Slider/Stepper/Segmented）。
  Future<void> adjust({
    required int steps,
    LogicalKeyboardKey up = LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey down = LogicalKeyboardKey.arrowLeft,
  }) async {
    final LogicalKeyboardKey key = steps >= 0 ? up : down;
    for (int i = 0; i < steps.abs(); i++) {
      await _key(key);
    }
  }

  /// 走全局 HibikiPopIntent 返回。
  Future<void> back() => _key(LogicalKeyboardKey.gameButtonB);
}
