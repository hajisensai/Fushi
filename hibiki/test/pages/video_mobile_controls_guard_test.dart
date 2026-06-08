import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-134 source guard: 手机视频顶栏过去硬塞 6~8 个图标，窄屏溢出/挤压 → 右侧
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

  test('移动顶栏自适应：宽屏平铺全部图标，窄屏收进 ⋮ 更多', () {
    final String body = region(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
      'void _showTrackMenu(',
    );
    final String topBar = region2(body);
    expect(topBar.contains('roomy'), isTrue, reason: '顶栏应按可用宽度(roomy)自适应');
    expect(body.contains('MediaQuery.of(context).size.width >= 600'), isTrue,
        reason: '用宽度阈值判定 roomy（横屏/平板平铺，竖屏收起）');
    expect(topBar.contains('Icons.more_vert'), isTrue, reason: '窄屏需有 ⋮ 更多入口');
    expect(topBar.contains('_showMobileMoreMenu('), isTrue,
        reason: '⋮ 打开移动更多菜单');
    // 宽屏分支平铺全部次级图标（用户要求横屏能全展开）。
    expect(topBar.contains('Icons.photo_camera_outlined'), isTrue,
        reason: '宽屏分支平铺截图');
    expect(topBar.contains('Icons.audiotrack'), isTrue, reason: '宽屏分支平铺音轨');
    expect(topBar.contains('Icons.tune'), isTrue, reason: '宽屏分支平铺设置');
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
