import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：桌面右键上下文菜单（TODO-048c）。整页 widget 测试依赖真实 libmpv
/// player（测试宿主无 libmpv，`load()` / `Player` 构造即抛），故按既有视频守卫范式
/// （见 video_player_keyboard_static_test.dart）在源码层钉死结构不变量。
void main() {
  final String page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  ).readAsStringSync();

  group('右键菜单触发与门控', () {
    test('视频控制层挂 onSecondaryTapUp（右键触发）', () {
      expect(page.contains('onSecondaryTapUp:'), isTrue,
          reason: '桌面右键须经 GestureDetector.onSecondaryTapUp 进入菜单');
      expect(
          page.contains('_handleSecondaryTap(details.globalPosition)'), isTrue,
          reason: '右键松手处的 globalPosition 作 showMenu 锚点');
    });

    test('右键菜单仅桌面（移动端门控 no-op）', () {
      // _handleSecondaryTap 第一行必是桌面门控，移动端不弹菜单。
      final int idx = page.indexOf('void _handleSecondaryTap(');
      expect(idx, greaterThan(0), reason: '必须有 _handleSecondaryTap 入口');
      final String body = page.substring(idx, idx + 400);
      expect(body.contains('if (!_isDesktopVideoControls) return;'), isTrue,
          reason: '移动端无右键，须 _isDesktopVideoControls 门控双保险');
    });

    test('菜单锚定 _videoControlsContext（全屏路由内可弹）', () {
      final int idx = page.indexOf('void _handleSecondaryTap(');
      final String body = page.substring(idx, idx + 1200);
      expect(body.contains('_videoControlsContext'), isTrue,
          reason: 'showMenu 须用 controls 子树 context，全屏路由复用同一 builder 才能弹出');
      expect(body.contains('showMenu<VoidCallback>('), isTrue,
          reason: '用 showMenu 弹 PopupMenu，自带锚点定位');
      expect(body.contains('RelativeRect.fromLTRB('), isTrue,
          reason: '右键位置须转成 RelativeRect 作菜单锚点');
    });

    test('菜单关闭后归还键盘焦点', () {
      final int idx = page.indexOf('void _handleSecondaryTap(');
      final String body = page.substring(idx, idx + 1400);
      expect(body.contains('_refocusVideo()'), isTrue,
          reason: '覆盖层夺焦后不会自动归还，菜单关闭须 _refocusVideo');
    });
  });

  group('菜单项复用既有动作（不重造）', () {
    // 取 _buildVideoContextMenuItems 方法体断言各项动作都接到既有 helper。
    final int idx = page.indexOf(
      'List<PopupMenuEntry<VoidCallback>> _buildVideoContextMenuItems(',
    );
    late final String items;
    setUpAll(() {
      expect(idx, greaterThan(0), reason: '必须有 _buildVideoContextMenuItems');
      // 截到下一个顶层方法前，覆盖整个菜单项列表。
      items = page.substring(idx, idx + 2000);
    });

    test('含播放/暂停', () {
      expect(items.contains('t.video_menu_play_pause'), isTrue);
      expect(items.contains('controller.playOrPause()'), isTrue);
    });

    test('含全屏切换', () {
      expect(items.contains('t.video_menu_fullscreen'), isTrue);
      expect(items.contains('_toggleVideoFullscreen('), isTrue);
    });

    test('含播放速度', () {
      expect(items.contains('t.video_setting_speed'), isTrue);
      expect(items.contains('_showSpeedMenu'), isTrue);
    });

    test('含字幕轨切换', () {
      expect(items.contains('t.video_menu_subtitle_track'), isTrue);
      expect(items.contains('_showSubtitleSourceMenu(controller)'), isTrue);
    });

    test('含字幕列表（TODO-069）', () {
      expect(items.contains('t.video_subtitle_list'), isTrue);
      expect(items.contains('_toggleSubtitleJumpList'), isTrue);
    });

    test('含音轨切换', () {
      expect(items.contains('t.video_audio_track'), isTrue);
      expect(items.contains('_showAudioTrackMenu(controller)'), isTrue);
    });

    test('含截图', () {
      expect(items.contains('t.video_screenshot'), isTrue);
      expect(items.contains('_saveScreenshot'), isTrue);
    });

    test('含锁定 / 沉浸模式（TODO-101）', () {
      expect(items.contains('t.video_menu_lock'), isTrue);
      expect(items.contains('_toggleImmersiveLock'), isTrue);
    });

    test('含跨字幕制卡（TODO-102）', () {
      expect(items.contains('t.video_menu_cross_subtitle'), isTrue);
      expect(items.contains('_toggleCrossSubtitleRecording'), isTrue);
    });

    test('着色器对比仅在启用着色器时出现', () {
      expect(items.contains('if (_hasShadersEnabled)'), isTrue,
          reason: '着色器对比项与控制条同条件（_hasShadersEnabled）');
      expect(items.contains('_toggleShaderCompare()'), isTrue);
    });
  });
}
