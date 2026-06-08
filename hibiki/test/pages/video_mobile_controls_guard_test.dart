import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-128 source guard: 手机视频顶栏过去硬塞 6~8 个图标，窄屏溢出/挤压 → 右侧
/// 图标被裁剪点不到（用户报「图标看得到但点了没反应」）。改为标准手机交互：顶栏
/// 只留 剧集列表(播放列表时) + ⋮ 更多，其余收进底部 sheet。media_kit 无 headless，
/// 锁调用点不变式。
void main() {
  final String src =
      File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync();

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test('移动顶栏改用 ⋮ 更多菜单，不再直接平铺 6+ 图标', () {
    final String body = region(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
      'void _showTrackMenu(',
    );
    final String topBar = region2(body);
    // 顶栏有「更多」入口。
    expect(topBar.contains('Icons.more_vert'), isTrue, reason: '移动顶栏需有 ⋮ 更多入口');
    expect(topBar.contains('_showMobileMoreMenu('), isTrue,
        reason: '⋮ 打开移动更多菜单');
    // 顶栏不再直接放这些次级动作图标（已收进 ⋮ sheet），否则窄屏溢出回归。
    expect(topBar.contains('Icons.photo_camera_outlined'), isFalse,
        reason: '截图应收进 ⋮ sheet，不在移动顶栏直接平铺');
    expect(topBar.contains('Icons.audiotrack'), isFalse,
        reason: '音轨应收进 ⋮ sheet');
    expect(topBar.contains('Icons.speed'), isFalse, reason: '倍速应收进 ⋮ sheet');
    expect(topBar.contains('Icons.tune'), isFalse, reason: '设置应收进 ⋮ sheet');
  });

  test('_showMobileMoreMenu 派发到全部 6 个既有 handler', () {
    final String menu = region(
      'Future<void> _showMobileMoreMenu(',
      'Widget _moreTile(',
    );
    expect(menu.contains('_saveScreenshot()'), isTrue);
    expect(menu.contains('_showSubtitleSourceMenu(controller)'), isTrue);
    expect(menu.contains('_showAudioTrackMenu(controller)'), isTrue);
    expect(menu.contains('_showSpeedMenu()'), isTrue);
    expect(menu.contains('_showEpisodeList()'), isTrue);
    expect(menu.contains('_showPlayerSettings()'), isTrue);
  });
}

/// 取 _mobileControlsTheme body 里 topButtonBar 那一段（到 bottomButtonBar 前）。
String region2(String mobileBody) {
  final int top = mobileBody.indexOf('topButtonBar:');
  final int bottom = mobileBody.indexOf('bottomButtonBar:');
  expect(top, greaterThanOrEqualTo(0), reason: 'missing topButtonBar');
  expect(bottom, greaterThan(top), reason: 'missing bottomButtonBar');
  return mobileBody.substring(top, bottom);
}
