import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

/// 源码守卫（TODO-1287）：沉浸模式退出按钮「不会消失」的回归防护。
///
/// 根因：沉浸态（[_immersiveLocked]）下锁按钮曾有「固定左侧解锁钮」与「拖到侧栏的锁」
/// 两条渲染路径，后者缺 2s 自动淡出门控（[_lockButtonVisible] || [_lockButtonHovered]
/// 决定显隐 + AnimatedOpacity 淡入淡出 + IgnorePointer 淡出后不拦点击）→ 常驻可见，
/// 用户报「沉浸模式按钮不会消失」。
///
/// 修复：[_withImmersiveLockAutoHide] wrapper 统一门控。沉浸布局（2026-10-25）之后沉浸态
/// 只剩一条渲染路径——沉浸布局的左右两条侧栏（含锁按钮）整层包在这个 wrapper 里。
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
        'Widget _withImmersiveLockAutoHide({required Widget child})',
      ),
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
      expect(
        body.contains('FadingChromeGate('),
        isTrue,
        reason: 'on-rail 沉浸退出钮应走共享门控 FadingChromeGate',
      );
      expect(
        body.contains('curve:'),
        isFalse,
        reason: '调用点不得覆盖曲线，否则绕开 FadingChromeGate 的 easeInOut 默认值',
      );
      expectFadingChromeGateContract();
      expect(
        body.contains('_lockButtonHoverKeepAlive(child: child)'),
        isTrue,
        reason: 'hover 保活让鼠标悬在按钮上时顶住可见并续命淡出定时',
      );
    },
  );

  test('沉浸态侧栏整层必须经 _withImmersiveLockAutoHide 包裹（不再裸渲染常驻可见）', () {
    final String railBody = _section(
      src,
      'Widget _buildVideoSideActionRail(',
      'Widget _buildVideoSideRailFor(',
    );
    final int lockedIdx = railBody.indexOf('if (_immersiveLocked.value)');
    expect(lockedIdx, greaterThanOrEqualTo(0), reason: '沉浸锁定态必须单独分支');
    final int wrapIdx = railBody.indexOf(
      '_withImmersiveLockAutoHide(',
      lockedIdx,
    );
    expect(
      wrapIdx,
      greaterThan(lockedIdx),
      reason: '沉浸态侧栏必须经 _withImmersiveLockAutoHide 自动淡出',
    );
    // wrapper 内包的是沉浸布局的两条侧栏（左右都走同一个循环）。
    final int railsIdx = railBody.indexOf(
      'VideoImmersiveSlot.railSlots',
      wrapIdx,
    );
    final int itemsIdx = railBody.indexOf(
      'items: _immersiveRailItems(',
      wrapIdx,
    );
    expect(railsIdx, greaterThan(wrapIdx), reason: 'wrapper 应包住沉浸布局的左右侧栏');
    expect(
      itemsIdx,
      greaterThan(wrapIdx),
      reason: '沉浸态侧栏按钮应取自沉浸布局（_immersiveRailItems）',
    );
  });
}
