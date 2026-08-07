import 'package:flutter/widgets.dart';

/// 淡出型 chrome 的统一门（BUG-1301 根因修复）：**不可见 ⇒ 不可点、不可聚焦**，
/// 三者绑死同一个 [visible] 判据，结构上消除「隐形但可聚焦」这类特殊状态。
///
/// 动机：视频页多处 chrome（剧集横轨、侧边沉浸锁按钮、on-rail 沉浸退出钮）淡出后
/// **留在树里**做 fade/slide 动画，旧实现只包 [IgnorePointer] 挡指针——但
/// [IgnorePointer] 挡不住焦点遍历：手柄 D-pad / Tab 仍能把焦点落进（或留在）
/// opacity=0 的 `InkWell(canRequestFocus: true)` 上。焦点高亮开启
/// （`FocusHighlightMode.traditional`）时，`FushiFocusRing` 按 primaryFocus 的
/// RenderBox 画 2.5px 空心框 → 画面上凭空出现一个空焦点框（BUG-1301 用户截图）。
///
/// [ExcludeFocus] 翻 excluding=true 时 Flutter 会自动把已持焦的子孙 unfocus 回
/// scope 的上一个持焦者（`FocusNode.descendantsAreFocusable` setter →
/// `unfocus(disposition: previouslyFocusedChild)`），故隐藏瞬间焦点自动撤离、
/// 无需宿主页面逐处补 reclaim。
///
/// 用法：替代裸 `IgnorePointer(ignoring: !visible) + AnimatedOpacity` 组合。需要
/// 额外动画（如剧集轨的 [AnimatedSlide]）放在 [child] 内层即可，几何/视觉不变。
class FadingChromeGate extends StatelessWidget {
  const FadingChromeGate({
    super.key,
    required this.visible,
    required this.duration,
    this.curve = Curves.easeInOut,
    required this.child,
  });

  /// chrome 当前是否可见。false 时同时：指针穿透、子树整体不可聚焦（已持焦的
  /// 子孙被自动撤离）、淡出到 opacity 0。
  final bool visible;

  /// 淡入淡出时长（与既有各 chrome 的动画时长保持一致，视觉零变化）。
  final Duration duration;

  /// 淡入淡出曲线。
  final Curve curve;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeFocus(
        excluding: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: duration,
          curve: curve,
          child: child,
        ),
      ),
    );
  }
}
