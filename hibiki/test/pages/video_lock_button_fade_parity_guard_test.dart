import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
}
