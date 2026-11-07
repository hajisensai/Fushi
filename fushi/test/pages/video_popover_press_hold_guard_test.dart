import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫（BUG-4226 ②，反馈 vskVvFumuG）：拖音量 / 倍速浮层的滑条时控制条照样
/// 自动隐藏。控制条只靠 hover 续命，拖动发的是 move 不是 hover，没人重排隐藏计时
/// → 控制条到点淡出、浮层随之被 `_applyControlsVisibilityFromMediaKit` 关掉。
///
/// 修复走已有的「按住控制条」通道（fork `holdVisible` ← `_controlsHeld`）：浮层里
/// 有指针按着即按住。组件行为（按下报 true、最后一个指针抬起 / 取消报 false、不抢
/// 子树手势）由 test/media/video/video_control_popover_hit_test.dart 真实渲染钉；
/// media_kit headless 跑不了播放页，这里在源码层钉页面接线的三处：
/// 1. 浮层内容包了 [VideoControlPopoverPressHold] 且回调接到按住写入点；
/// 2. `_syncControlsHold` 把这一来源并进 `_controlsHeld`；
/// 3. 关浮层时放开按住（按住中被 Esc / 门控关掉时组件卸载、收不到抬起）。
void main() {
  late String src;

  setUpAll(() {
    src = maskComments(readVideoFushiSource());
  });

  test('popover content is wrapped in the press-hold reporter on all '
      'platforms', () {
    final String body = methodBody(
      src,
      'Widget _controlPopoverHoverKeepAlive({required Widget child})',
    );
    final int hold = body.indexOf('VideoControlPopoverPressHold(');
    final int desktopGate = body.indexOf('if (!_isDesktopVideoControls)');
    expect(hold, greaterThanOrEqualTo(0), reason: '浮层内容没包按住上报');
    expect(hold < desktopGate, isTrue, reason: '按住续命必须在桌面门控之前包上（移动端拖滑条同样要按住）');
    expect(body, contains('onPressedChanged: _setControlPopoverPressed'));
  });

  test('press hold feeds _controlsHeld and the popover dismiss gate', () {
    final String setter = methodBody(
      src,
      'void _setControlPopoverPressed(bool pressed)',
    );
    expect(
      setter,
      contains('_controlPopoverHoverDismiss.setPressed(pressed)'),
      reason: '按住必须同时进浮层自己的收起判据（拖出浮层边界会 onExit）',
    );
    expect(setter, contains('_syncControlPopoverPressHold();'));
    final String pressSync = methodBody(
      src,
      'void _syncControlPopoverPressHold()',
    );
    expect(
      pressSync,
      contains(
        '_controlsHoldPopoverPress = _controlPopoverHoverDismiss.pressed;',
      ),
    );
    expect(pressSync, contains('_syncControlsHold();'));
    final String sync = methodBody(src, 'void _syncControlsHold()');
    expect(sync, contains('_controlsHoldPopoverPress'));
  });

  test('anchor and panel hover changes go through the dismiss gate', () {
    // 收起判据只有一处（VideoControlPopoverHoverDismiss，行为由
    // test/media/video/video_control_popover_hover_dismiss_test.dart 钉）；页面不得
    // 绕开它自建只看悬停的收起计时。
    final String anchor = methodBody(src, 'Widget _controlPopoverAnchor({');
    expect(
      anchor,
      contains(
        'onExit: (_) => _controlPopoverHoverDismiss.setAnchorHovered(false)',
      ),
    );
    final String keepAlive = methodBody(
      src,
      'Widget _controlPopoverHoverKeepAlive({required Widget child})',
    );
    expect(
      keepAlive,
      contains(
        'onExit: (_) => _controlPopoverHoverDismiss.setPanelHovered(false)',
      ),
    );
    expect(src.contains('_controlPopoverHideTimer'), isFalse);
    expect(src.contains('_scheduleControlPopoverHide'), isFalse);
  });

  test('closing the popover releases the press hold', () {
    final String body = methodBody(src, 'void _hideControlPopover()');
    expect(body, contains('_controlPopoverHoverDismiss.closed()'));
    expect(body, contains('_syncControlPopoverPressHold();'));
  });
}
