import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PR#910 审查必修 ②（BUG-1419 症状回归守卫）：`onPointerCancel` 绝不前置坐标。
///
/// 为什么在 hibiki 侧做源码扫描：真值来源 `custom_platform_view.dart` 属 vendored fork
/// （`packages/flutter_inappwebview_windows`），且 `flutter_inappwebview_windows` 只在
/// `dependency_overrides` 里（不是 fushi 的直接依赖），fushi 的测试无法 import 它的
/// Dart API（`depend_on_referenced_packages` 会让 `dart analyze` 直接 exit 1）。行为侧
/// 已由该包自己的 `test/mouse_button_mask_diff_test.dart` 覆盖，这里钉死接线结构。
///
/// 回归形态（BUG-1652 引入、BUG-1419 症状重现）：
///   ① `GestureBinding.cancelPointer` 合成的 `PointerCancelEvent` 只传 `pointer`，
///      其余走默认值 → `position` 恒为 `Offset.zero`（framework `events.dart`）。
///   ② native 的 `setCursorPos` 不是纯赋值：`in_app_webview.cpp` 写完 `lastCursorPos_`
///      之后，还会用**翻转前**的 `virtualKeys_.state()` 发一个 `MOUSE_EVENT_KIND_MOVE`。
/// 两条叠加：取消时左键位仍是 down，于是先发出「带左键按下的 MOUSE_MOVE 到 (0,0)」，
/// Blink 判为拖拽，把选区从锚点一路刷到文档左上角 —— 正是用户报的「鼠标一动就刷蓝
/// 选区」。develop 版 cancel 只补 up、沿用最后一次有效的 `lastCursorPos_`，没有这个问题。
void main() {
  final File view = File(
      '../packages/flutter_inappwebview_windows/lib/src/in_app_webview/custom_platform_view.dart');

  late String src;

  setUpAll(() {
    expect(view.existsSync(), isTrue,
        reason: 'custom_platform_view.dart 不存在，fork 路径变了须更新守卫');
    src = view.readAsStringSync().replaceAll('\r\n', '\n');
  });

  test('规划器把坐标建模成可空：没有可信坐标就不下发 setCursorPos', () {
    // 断言的关键字面量：'required Offset? position,'
    expect(src.contains('required Offset? position,'), isTrue,
        reason: '坐标必须可空——cancel 事件根本没有可信坐标，用 Offset.zero 冒充'
            '会让 native 把光标挪到 (0,0)');
    // 断言的关键字面量：
    // 'if (position != null) (position: position, buttonTransition: null),'
    expect(
        src.contains(
            'if (position != null) (position: position, buttonTransition: null),'),
        isTrue,
        reason: '坐标 dispatch 必须条件化；无条件前置就是本次回归的根因');
  });

  test('onPointerCancel 只走按钮差分，坐标传 null', () {
    const String cancelAnchor = 'onPointerCancel: (ev) {';
    const String moveAnchor = 'onPointerMove: (ev) {';
    expect(cancelAnchor.allMatches(src).length, 1,
        reason: 'onPointerCancel 锚点必须唯一，否则窗口会被同形 token 抢走');
    expect(moveAnchor.allMatches(src).length, 1,
        reason: 'onPointerMove 锚点必须唯一，否则窗口会被同形 token 抢走');
    final int start = src.indexOf(cancelAnchor);
    final int end = src.indexOf(moveAnchor, start);
    expect(end, greaterThan(start),
        reason: 'onPointerCancel 分支边界无法定位（onPointerMove 必须紧随其后）');
    final String cancelBody = src.substring(start, end);

    // 断言的关键字面量：'_syncMouseInput(null, ev.buttons);'
    expect(cancelBody.contains('_syncMouseInput(null, ev.buttons);'), isTrue,
        reason: 'cancel 必须以 null 坐标补发 up，沿用 native 最后一次有效的 '
            'lastCursorPos_');
    // 断言的关键字面量（反向）：'_syncMouseInput(ev.localPosition'
    expect(cancelBody.contains('_syncMouseInput(ev.localPosition'), isFalse,
        reason: 'BUG-1419 回归：cancel 的 ev.localPosition 是 Offset.zero，'
            '前置它会发出「带左键按下的 MOVE 到 (0,0)」→ 选区被刷到文档左上角');
  });

  test('带真实坐标的四个入口不受影响，down 仍先落坐标（BUG-1652 不回退）', () {
    final int positional =
        '_syncMouseInput(ev.localPosition, ev.buttons)'.allMatches(src).length;
    expect(positional, greaterThanOrEqualTo(4),
        reason: 'hover / down / up / move 四个入口都必须继续带坐标同步，'
            '实际只有 $positional 处');
  });
}
