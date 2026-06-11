import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-101 锁定 / 沉浸模式的源码守卫。
///
/// media_kit 跑不了 headless，全屏路由 + 控制条 hover / 点击都无法在 widget 测试里真实
/// 驱动，故把锁定态的不变量钉在 `video_hibiki_page.dart` / `video_player_shortcuts.dart`
/// 的接线点（参照 TODO-069 字幕跳转列表守卫范式）。锁定态四条核心不变量：
/// ① 可见性用 ValueNotifier（全屏路由也响应，不靠裸 setState）；
/// ② 锁定态控制条不弹（gate `AdaptiveVideoControls` 的指针 + poke 在锁定时早返回）；
/// ③ 锁定态查词 / 快捷键链路未被禁用（IgnorePointer 只过滤指针、字幕 overlay 在其上）；
/// ④ 锁屏入口 + 常驻解锁出口都可达（桌面 + 移动入口按钮 + 常驻解锁层 + Shift+L）。
void main() {
  late String src;
  late String shortcuts;

  setUpAll(() {
    src = File('lib/src/pages/implementations/video_hibiki_page.dart')
        .readAsStringSync();
    shortcuts = File('lib/src/media/video/video_player_shortcuts.dart')
        .readAsStringSync();
  });

  test('① 锁定可见性用 ValueNotifier（全屏路由也响应），并在 dispose 释放', () {
    expect(
      src.contains('ValueNotifier<bool> _immersiveLocked'),
      isTrue,
      reason: '锁定态必须是 ValueNotifier，否则全屏下锁屏按钮 / 快捷键翻不动',
    );
    expect(
      src.contains('valueListenable: _immersiveLocked'),
      isTrue,
      reason: '锁定态层未监听 _immersiveLocked（全屏路由不随页面 setState 重建，BUG-120）',
    );
    expect(src.contains('_immersiveLocked.dispose();'), isTrue,
        reason: 'notifier 未在 dispose 释放');
  });

  test('② 锁定态 gate AdaptiveVideoControls 的指针（控制条不弹）', () {
    // AdaptiveVideoControls 必须被 IgnorePointer 包住、ignoring 跟随锁定态，鼠标 hover
    // 收不到 → media_kit 控制条不被唤起。
    final int idx = src.indexOf('IgnorePointer(');
    expect(idx, greaterThanOrEqualTo(0),
        reason: '锁定态必须用 IgnorePointer 拦掉送往 media_kit controls 的指针');
    // ignoring 必须绑定锁定态变量（而非常量）。
    expect(
      RegExp(r'IgnorePointer\(\s*ignoring: locked,\s*child: AdaptiveVideoControls\(state\),')
          .hasMatch(src),
      isTrue,
      reason: 'IgnorePointer.ignoring 必须跟随锁定态、child 必须是 AdaptiveVideoControls',
    );
  });

  test('② poke 在锁定态早返回（键盘跳句不再弹控制条）', () {
    // _pokeControlsVisible 在桌面门控之后、派发合成 hover 之前，必须先判锁定态早返回。
    final int pokeIdx = src.indexOf('void _pokeControlsVisible()');
    expect(pokeIdx, greaterThanOrEqualTo(0));
    final int dispatchIdx =
        src.indexOf('GestureBinding.instance.handlePointerEvent', pokeIdx);
    final int gateIdx =
        src.indexOf('if (_immersiveLocked.value) return;', pokeIdx);
    expect(gateIdx, greaterThanOrEqualTo(0),
        reason: 'poke 未在锁定态早返回（锁定态键盘交互会弹控制条）');
    expect(gateIdx, lessThan(dispatchIdx), reason: '锁定态早返回必须排在派发合成 hover 之前');
  });

  test('③ 锁定态查词 / 快捷键不被禁用（IgnorePointer 不裹字幕 overlay / 快捷键）', () {
    // 字幕逐字查词 overlay 必须在 AdaptiveVideoControls 之上、且不被 IgnorePointer 包住。
    final int controlsIdx = src.indexOf('AdaptiveVideoControls(state)');
    final int overlayIdx = src.indexOf('VideoSubtitleOverlay(');
    expect(controlsIdx, greaterThanOrEqualTo(0));
    expect(overlayIdx, greaterThanOrEqualTo(0));
    expect(overlayIdx, greaterThan(controlsIdx),
        reason: '字幕查词 overlay 必须叠在 controls 之上，锁定态点字幕仍能查词');
    // 锁定态绝不能把快捷键表清空 / gate 掉：keyboardShortcuts 仍整表传给主题。
    expect(
        src.contains('keyboardShortcuts: _videoKeyboardShortcuts(controller)'),
        isTrue,
        reason: '快捷键表必须始终传给 media_kit 主题（锁定态快捷键不被禁用）');
  });

  test('④ 锁屏入口按钮挂在桌面 + 移动控制条（两态都可进入）', () {
    const String needle = 'onPressed: _toggleImmersiveLock,';
    final int count = needle.allMatches(src).length;
    // 桌面入口 + 移动入口 + 常驻解锁层 = 3 处；至少桌面 + 移动两个入口。
    expect(count, greaterThanOrEqualTo(2), reason: '桌面 + 移动控制条都应有锁屏入口按钮');
    expect(
        src.contains('Icon(Icons.lock_outline, size: _videoControlIconSize)'),
        isTrue,
        reason: '锁屏入口按钮应是 lock 图标');
  });

  test('④ 锁定态有常驻解锁层（唯一常驻 chrome，挂在 controls Stack）', () {
    expect(src.contains('_buildLockOverlay(),'), isTrue,
        reason: '常驻解锁层未挂进 controls Stack（全屏将看不到解锁按钮）');
    expect(src.contains('Widget _buildLockOverlay()'), isTrue,
        reason: '缺常驻解锁层构建函数');
    // 解锁层点击退出锁定。
    final int idx = src.indexOf('Widget _buildLockOverlay()');
    expect(
        src.indexOf('onPressed: _toggleImmersiveLock,', idx), greaterThan(idx),
        reason: '常驻解锁按钮未接到 _toggleImmersiveLock');
  });

  test('④ Shift+L 切换锁定（与裸 L 字幕列表区分，未撞键），并接到本页 action', () {
    expect(
      shortcuts.contains(
          'const SingleActivator(LogicalKeyboardKey.keyL, shift: true):'),
      isTrue,
      reason: 'Shift+L 未绑定切换锁定',
    );
    expect(shortcuts.contains('actions.toggleImmersiveLock'), isTrue,
        reason: 'Shift+L 未接到 toggleImmersiveLock action');
    expect(src.contains('toggleImmersiveLock: _toggleImmersiveLock'), isTrue,
        reason: 'toggleImmersiveLock action 未接到 _toggleImmersiveLock');
    // 裸 L 仍是字幕列表（Shift+L 不能撞掉它）。
    expect(
      shortcuts.contains('const SingleActivator(LogicalKeyboardKey.keyL): '
          'actions.toggleSubtitleList'),
      isTrue,
      reason: '裸 L（字幕列表）被 Shift+L 撞掉',
    );
  });

  test('Esc 优先解锁（最外层沉浸态，排在退全屏 / 退页之前）', () {
    final int escIdx = src.indexOf('escape: () {');
    expect(escIdx, greaterThanOrEqualTo(0), reason: '缺 escape 回调');
    final int unlockIdx = src.indexOf('_immersiveLocked.value', escIdx);
    final int fullscreenExitIdx =
        src.indexOf('_exitVideoFullscreen(ctx)', escIdx);
    final int exitIdx = src.indexOf('_handleBackOrExit()', escIdx);
    expect(unlockIdx, greaterThanOrEqualTo(0), reason: 'Esc 未在锁定态先解锁');
    expect(unlockIdx, lessThan(fullscreenExitIdx), reason: 'Esc 解锁必须排在退全屏之前');
    expect(unlockIdx, lessThan(exitIdx), reason: 'Esc 解锁必须排在退页之前（逐级退出）');
  });
}
