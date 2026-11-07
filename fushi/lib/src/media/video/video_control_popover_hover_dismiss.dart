import 'dart:async';

/// 音量 / 倍速轻浮层的「何时自动收起」判据（BUG-4226 续）。
///
/// 浮层有三条保持打开的来源，任一成立都不收：
/// - **固定**（[pinned]）：点击打开的浮层常驻，只能再点一次 / Esc / 点浮层外关；
/// - **悬停**：指针在锚点按钮或浮层本体上（[setAnchorHovered] / [setPanelHovered]）；
/// - **按住**（[pressed]）：浮层里有指针按着（拖音量 / 倍速滑条）。
///
/// 「按住」必须单独算一条：Flutter 在 PointerMoveEvent（按住拖动）时也会重做鼠标
/// 命中测试（`RendererBinding.dispatchEvent`），所以拖滑条时指针一出浮层边界，浮层的
/// `MouseRegion.onExit` 照样触发——只看悬停的话，拖到一半浮层与滑条就被收掉。
/// 松手时若已不在锚点 / 浮层上，按悬停规则补一次延迟收起。
///
/// 纯 Dart 状态机，不碰 widget；收起动作经 `onDismiss` 交给宿主（宿主收起时调
/// [closed] 清状态）。
class VideoControlPopoverHoverDismiss {
  VideoControlPopoverHoverDismiss({
    required void Function() onDismiss,
    this.delay = const Duration(milliseconds: 180),
  }) : _onDismiss = onDismiss;

  /// 指针离开锚点 / 浮层后等多久再收（给从锚点挪到浮层的路上留缝）。
  final Duration delay;

  final void Function() _onDismiss;
  bool _anchorHovered = false;
  bool _panelHovered = false;
  bool _pinned = false;
  bool _pressed = false;
  Timer? _hideTimer;

  /// 浮层是否被点击固定。
  bool get pinned => _pinned;

  /// 浮层里是否有指针按着。
  bool get pressed => _pressed;

  /// 指针是否在锚点或浮层上。
  bool get hovered => _anchorHovered || _panelHovered;

  /// 是否有一次延迟收起在排队（测试 / 诊断用）。
  bool get hidePending => _hideTimer?.isActive ?? false;

  /// 浮层打开（或同一浮层被再次触发）。[kindChanged] 为换了一种浮层时直接取
  /// [pinned]；同一种浮层再次打开只能把「悬停打开」升级成「固定」，不降级。
  void opened({required bool kindChanged, required bool pinned}) {
    _cancelHide();
    if (kindChanged) {
      _pinned = pinned;
    } else if (pinned) {
      _pinned = true;
    }
  }

  /// 锚点按钮悬停变化；离开时排一次延迟收起。
  void setAnchorHovered(bool hovered) {
    _anchorHovered = hovered;
    if (!hovered) _scheduleHide();
  }

  /// 浮层本体悬停变化；离开时排一次延迟收起。
  void setPanelHovered(bool hovered) {
    _panelHovered = hovered;
    if (!hovered) _scheduleHide();
  }

  /// 浮层里按住 / 松开。返回按住状态是否真的变了（宿主据此同步控制条按住）。
  ///
  /// 按下撤掉排队中的收起；松开时若已不在锚点 / 浮层上，按悬停规则补一次收起。
  bool setPressed(bool pressed) {
    if (_pressed == pressed) return false;
    _pressed = pressed;
    if (pressed) {
      _cancelHide();
    } else if (!hovered) {
      _scheduleHide();
    }
    return true;
  }

  /// 宿主已收起浮层：清掉固定 / 按住与排队中的收起，悬停由各自 `onExit` 维护。
  /// 返回收起前是否处于按住（按住中被 Esc / 门控关掉时组件卸载、收不到抬起，
  /// 宿主据此放开控制条按住）。
  bool closed() {
    _cancelHide();
    _pinned = false;
    final bool wasPressed = _pressed;
    _pressed = false;
    return wasPressed;
  }

  void dispose() => _cancelHide();

  void _cancelHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _scheduleHide() {
    _cancelHide();
    if (_pinned || _pressed) return;
    _hideTimer = Timer(delay, () {
      _hideTimer = null;
      if (_pinned || _pressed || hovered) return;
      _onDismiss();
    });
  }
}
