import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _section(String src, String startToken, String endToken) {
  final int start = src.indexOf(startToken);
  expect(start, greaterThanOrEqualTo(0), reason: '缺少 $startToken');
  final int end = src.indexOf(endToken, start);
  expect(end, greaterThan(start), reason: '$startToken 后缺少 $endToken');
  return src.substring(start, end);
}

/// 源码守卫（TODO-435）：沉浸 / 锁按钮的显隐淡入淡出速度与 media_kit 视频控制条一致。
///
/// 根因：锁按钮 [_buildSideLockButton] 的 AnimatedOpacity 旧实现用
/// `duration: const Duration(milliseconds: 200)` + 默认 linear 曲线，而 media_kit
/// 控制条用 `controlsTransitionDuration`（桌面默认 150ms / 移动默认 300ms）+ easeInOut，
/// 两者既不同时长也不同曲线 → 淡入淡出不同步。
///
/// 修复（单一真相源，消除各写各的 200ms）：新增派生 getter
/// [_videoControlsTransitionDuration]（桌面 150ms / 移动 300ms），锁按钮 AnimatedOpacity
/// 改读它 + `Curves.easeInOut`，并让桌面 / 移动控制主题各显式写
/// `controlsTransitionDuration: _videoControlsTransitionDuration`，三处读同一真相源。
///
/// media_kit controls 跑不了 headless（[_buildSideLockButton] / 控制主题都需真 controller），
/// 故锁源码结构不变量（与 [video_immersion_button_hover_guard_test] 同理）。
void main() {
  final File page =
      File('lib/src/pages/implementations/video_hibiki_page.dart');

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  test('存在派生 getter _videoControlsTransitionDuration（桌面 150ms / 移动 300ms）', () {
    expect(
      src.contains(
          'Duration get _videoControlsTransitionDuration => _isDesktopVideoControls'),
      isTrue,
      reason: '应有按桌面 / 移动派生的 _videoControlsTransitionDuration 单一真相源',
    );
    expect(
      src.contains('? const Duration(milliseconds: 150)'),
      isTrue,
      reason: '桌面应为 150ms（对齐 media_kit 桌面默认）',
    );
    expect(
      src.contains(': const Duration(milliseconds: 300)'),
      isTrue,
      reason: '移动应为 300ms（对齐 media_kit 移动默认）',
    );
  });

  test(
      '锁按钮 AnimatedOpacity 用 _videoControlsTransitionDuration + Curves.easeInOut（不回退 200ms / linear）',
      () {
    final int start = src.indexOf('Widget _buildSideLockButton()');
    expect(start, greaterThan(0), reason: '应有 _buildSideLockButton 构造器');
    final int end = src.indexOf('IconData _volumeIconFor(', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);

    expect(
      body.contains('duration: _videoControlsTransitionDuration'),
      isTrue,
      reason: '锁按钮淡入淡出时长应读控制条同源真相源（不再硬编码 200ms）',
    );
    expect(
      body.contains('curve: Curves.easeInOut'),
      isTrue,
      reason: '锁按钮淡入淡出应用 easeInOut（对齐控制条，不再用默认 linear）',
    );
    expect(
      body.contains('duration: const Duration(milliseconds: 200)'),
      isFalse,
      reason: '锁按钮不得回退到硬编码 200ms（TODO-435 回归）',
    );
  });

  test('桌面控制主题显式设 controlsTransitionDuration: _videoControlsTransitionDuration',
      () {
    final int start = src.indexOf(
        'MaterialDesktopVideoControlsThemeData _desktopControlsTheme(');
    expect(start, greaterThan(0), reason: '应有 _desktopControlsTheme 构造器');
    final int end = src.indexOf(
        'MaterialVideoControlsThemeData _mobileControlsTheme(', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(
      body.contains(
          'controlsTransitionDuration: _videoControlsTransitionDuration'),
      isTrue,
      reason: '桌面控制主题应读锁按钮同源的淡入淡出时长',
    );
  });

  test('移动控制主题显式设 controlsTransitionDuration: _videoControlsTransitionDuration',
      () {
    final int start =
        src.indexOf('MaterialVideoControlsThemeData _mobileControlsTheme(');
    expect(start, greaterThan(0), reason: '应有 _mobileControlsTheme 构造器');
    final String body = src.substring(start);
    expect(
      body.contains(
          'controlsTransitionDuration: _videoControlsTransitionDuration'),
      isTrue,
      reason: '移动控制主题应读锁按钮同源的淡入淡出时长',
    );
  });

  test('right rail gate 监听所有强压制态，gate 与 rebuild 来源一致', () {
    final String railBody = _section(
      src,
      'Widget _buildVideoSideActionRail(',
      'Widget _buildVideoSideRailFor(',
    );
    final int mergeStart = railBody.indexOf('Listenable.merge(<Listenable>[');
    expect(mergeStart, greaterThanOrEqualTo(0),
        reason: 'rail 必须用 Listenable.merge 汇总显隐来源');
    final int mergeEnd = railBody.indexOf(']),', mergeStart);
    expect(mergeEnd, greaterThan(mergeStart));
    final String mergeBody = railBody.substring(mergeStart, mergeEnd);

    for (final String listenable in <String>[
      '_videoControlsVisible',
      '_railHovered',
      '_immersiveLocked',
      '_videoSidePanel',
      '_subtitleListVisible',
      '_videoControlEditMode',
    ]) {
      expect(mergeBody.contains(listenable), isTrue,
          reason: 'rail Listenable.merge 缺少 $listenable，gate 变化会不同步');
    }

    final String gateBody = _section(
      src,
      'bool get _videoSideActionRailStronglySuppressed',
      'void _applyControlsVisibilityFromMediaKit()',
    );
    expect(gateBody.contains('_subtitleListVisible.value'), isTrue,
        reason: '字幕列表打开时普通 right rail 必须被强压制');
    expect(gateBody.contains('_videoControlEditMode.value'), isTrue,
        reason: '画面编辑模式打开时普通 right rail 必须被强压制');
    expect(gateBody.contains('_videoSidePanel.value != null'), isTrue,
        reason: '侧栏 / 面板打开时普通 right rail 必须被强压制');
    expect(
      railBody.contains('if (_videoSideActionRailStronglySuppressed)'),
      isTrue,
      reason: 'rail builder 必须使用同一个强压制 gate，不能分散写局部门控',
    );
  });

  test('进入字幕列表、侧栏、画面编辑、沉浸锁会清 rail hover，退出不恢复旧 hover', () {
    final String clearHoverBody = _section(
      src,
      'void _clearRailHover()',
      'void _applyControlsVisibilityFromMediaKit()',
    );
    expect(clearHoverBody.contains('_railHovered.value = false'), isTrue,
        reason: '清 hover 必须直接把 _railHovered 置 false');
    expect(clearHoverBody.contains('_railHovered.value = true'), isFalse,
        reason: '清 hover helper 不能恢复旧 hover');

    final Map<String, String> enterHooks = <String, String>{
      'void _toggleSubtitleJumpList()': '_subtitleListVisible.value = true',
      'void _showVideoSidePanel(':
          '_videoSidePanel.value = _VideoSidePanelState',
      'void _showVideoControlEditOverlay()':
          '_videoControlEditMode.value = true',
      'void _toggleImmersiveLock()': 'if (next)',
    };

    for (final MapEntry<String, String> hook in enterHooks.entries) {
      final int start = src.indexOf(hook.key);
      expect(start, greaterThanOrEqualTo(0), reason: '缺少 ${hook.key}');
      final int clearIdx = src.indexOf('_clearRailHover();', start);
      final int enterIdx = src.indexOf(hook.value, start);
      expect(clearIdx, greaterThanOrEqualTo(0),
          reason: '${hook.key} 进入强压制态时必须清 _railHovered');
      expect(enterIdx, greaterThan(clearIdx),
          reason: '${hook.key} 应先清 hover，再进入强压制态');
    }

    final String hideSidePanel = _section(
      src,
      'void _hideVideoSidePanel()',
      'String _videoSidePanelTitle(',
    );
    final String hideEdit = _section(
      src,
      'void _hideVideoControlEditOverlay({bool revealControls = true})',
      'Future<void> _clearWindowAspectRatioLock()',
    );
    expect(hideSidePanel.contains('_railHovered.value = true'), isFalse,
        reason: '退出侧栏不应恢复旧 hover，只能等待真实 hover / 控制条状态');
    expect(hideEdit.contains('_railHovered.value = true'), isFalse,
        reason: '退出画面编辑不应恢复旧 hover，只能等待真实 hover / 控制条状态');
  });
}
