import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// 源码守卫（TODO-1287）：沉浸模式退出按钮「不会消失」的回归防护。
///
/// 根因：沉浸态（[_immersiveLocked]）下，若用户把沉浸锁按钮拖到屏幕左 / 右 rail 槽
/// （`lockOnSideRail`），[_buildVideoSideActionRail] 走 [_buildVideoSideRailFor]
/// `(immersiveOnly: true)` 把它渲染成**裸 IconButton**，缺失默认路径
/// [_buildSideLockButton] 的 2s 自动淡出门控（[_lockButtonVisible] || [_lockButtonHovered]
/// 决定显隐 + AnimatedOpacity 淡入淡出 + IgnorePointer 淡出后不拦点击）→ 常驻可见，
/// 用户报「沉浸模式按钮不会消失」。
///
/// 修复：新增 [_withImmersiveLockAutoHide] wrapper，把 on-rail 沉浸退出 chrome 包进与
/// [_buildSideLockButton] **同款**的可见性门控，两条渲染路径淡出行为归一。
///
/// media_kit controls 跑不了 headless（rail / 锁按钮都需真 controller），故锁源码结构
/// 不变量（与 [video_lock_button_fade_parity_guard_test] /
/// [video_immersion_button_hover_guard_test] 同理）。
String _section(String src, String startToken, String endToken) {
  final int start = src.indexOf(startToken);
  expect(start, greaterThanOrEqualTo(0), reason: '缺少 $startToken');
  final int end = src.indexOf(endToken, start);
  expect(end, greaterThan(start), reason: '$startToken 后缺少 $endToken');
  return src.substring(start, end);
}

void main() {
  late String src;
  setUpAll(() {
    src = readVideoFushiSource();
  });

  test('存在 _withImmersiveLockAutoHide wrapper', () {
    expect(
      src.contains(
          'Widget _withImmersiveLockAutoHide({required Widget child})'),
      isTrue,
      reason: '应有沉浸退出按钮自动淡出 wrapper _withImmersiveLockAutoHide',
    );
  });

  test(
      '_withImmersiveLockAutoHide 与默认锁按钮同款门控（判据 / 时长 / 曲线 / IgnorePointer / hover 保活）',
      () {
    final String body = _section(
      src,
      'Widget _withImmersiveLockAutoHide({required Widget child})',
      'Widget _buildVideoSideActionRail(',
    );
    expect(
      body.contains('_lockButtonVisible.value || _lockButtonHovered.value'),
      isTrue,
      reason: '可见性判据应与默认锁按钮一致：_lockButtonVisible OR _lockButtonHovered',
    );
    expect(
      body.contains('duration: _videoControlsTransitionDuration'),
      isTrue,
      reason: '淡入淡出时长应读控制条同源真相源（不再硬编码）',
    );
    // BUG-1301：曲线 / IgnorePointer / AnimatedOpacity 三项搬进共享
    // FadingChromeGate，调用点只剩 visible + duration。断言随之拆两半：
    // 这里断「走了共享门控且没覆盖默认曲线」，组件那半由
    // expectFadingChromeGateContract 断。
    expect(body.contains('FadingChromeGate('), isTrue,
        reason: 'on-rail 沉浸退出钮应走共享门控 FadingChromeGate');
    expect(body.contains('curve:'), isFalse,
        reason: '调用点不得覆盖曲线，否则绕开 FadingChromeGate 的 easeInOut 默认值');
    expectFadingChromeGateContract();
    expect(body.contains('_lockButtonHoverKeepAlive(child: child)'), isTrue,
        reason: 'hover 保活让鼠标悬在按钮上时顶住可见并续命淡出定时');
  });

  test('沉浸态 on-rail 分支必须经 _withImmersiveLockAutoHide 包裹（不再裸渲染常驻可见）', () {
    final String railBody = _section(
      src,
      'Widget _buildVideoSideActionRail(',
      'Widget _buildVideoSideRailFor(',
    );
    // lockOnSideRail 分支：immersiveOnly rail 必须被 wrapper 包裹。
    final int wrapIdx = railBody.indexOf('_withImmersiveLockAutoHide(');
    expect(wrapIdx, greaterThanOrEqualTo(0),
        reason: 'on-rail 沉浸锁按钮必须经 _withImmersiveLockAutoHide 自动淡出');
    // wrapper 内包的正是 immersiveOnly 左右 rail。
    final int leftIdx = railBody.indexOf('left(immersiveOnly: true)', wrapIdx);
    final int rightIdx =
        railBody.indexOf('right(immersiveOnly: true)', wrapIdx);
    expect(leftIdx, greaterThan(wrapIdx),
        reason: 'wrapper 应包住 left(immersiveOnly: true)');
    expect(rightIdx, greaterThan(wrapIdx),
        reason: 'wrapper 应包住 right(immersiveOnly: true)');
  });
}
