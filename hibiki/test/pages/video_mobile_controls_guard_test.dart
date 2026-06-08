import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-134 follow-up source guard: mobile video controls must not depend on a
/// top-right overflow menu, and the bottom bar must stay sparse enough for
/// touch targets on an unscaled phone viewport.
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

  test('mobile top bar exposes actions directly without a more menu', () {
    final String body = region(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
      'void _showTrackMenu(',
    );
    final String topBar = topButtonBarRegion(body);
    expect(topBar.contains('Icons.more_vert'), isFalse,
        reason: '手机未放大时右上角三点点不到，移动端顶栏不应再依赖更多入口');
    expect(topBar.contains('_showMobileMoreMenu('), isFalse,
        reason: '三点菜单入口已取消，不应留下调用点');
    expect(body.contains('MediaQuery.of(context).size.width >= 600'), isFalse,
        reason: '移动端不再做窄屏藏三点/宽屏全展开分支');
    expect(topBar.contains('Icons.subtitles'), isTrue, reason: '字幕源必须在顶栏直接可点');
    expect(topBar.contains('Icons.audiotrack'), isTrue, reason: '音轨必须在顶栏直接可点');
    expect(topBar.contains('Icons.tune'), isTrue, reason: '播放器设置必须在顶栏直接可点');
    expect(topBar.contains('Icons.photo_camera_outlined'), isTrue,
        reason: '取消三点后截图入口仍应在顶栏直接可点，不能丢失原功能');
    expect(topBar.contains('Icons.speed'), isFalse,
        reason: '倍速可从设置面板进入，不占手机顶栏空间');
  });

  test('mobile bottom bar keeps only core playback controls', () {
    final String body = region(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
      'void _showTrackMenu(',
    );
    final String bottomBar = bottomButtonBarRegion(body);
    expect(bottomBar.contains('MaterialPositionIndicator'), isTrue);
    expect(bottomBar.contains('MaterialPlayOrPauseButton'), isTrue);
    expect(bottomBar.contains('MaterialFullscreenButton'), isTrue);
    expect(bottomBar.contains('Icons.replay_10'), isFalse,
        reason: '底栏按钮过多会挤出手机屏幕，10 秒后退不放底栏');
    expect(bottomBar.contains('Icons.forward_10'), isFalse,
        reason: '底栏按钮过多会挤出手机屏幕，10 秒前进不放底栏');
    expect(bottomBar.contains('Icons.skip_previous'), isTrue,
        reason: '看字幕时前一句仍是核心播放控制，保留在底栏');
    expect(bottomBar.contains('Icons.skip_next'), isTrue,
        reason: '看字幕时后一句仍是核心播放控制，保留在底栏');
  });
}

String topButtonBarRegion(String mobileBody) {
  final int top = mobileBody.indexOf('topButtonBar:');
  final int bottom = mobileBody.indexOf('bottomButtonBar:');
  expect(top, greaterThanOrEqualTo(0), reason: 'missing topButtonBar');
  expect(bottom, greaterThan(top), reason: 'missing bottomButtonBar');
  return mobileBody.substring(top, bottom);
}

String bottomButtonBarRegion(String mobileBody) {
  final int bottom = mobileBody.indexOf('bottomButtonBar:');
  final int end = mobileBody.indexOf('],', bottom);
  expect(bottom, greaterThanOrEqualTo(0), reason: 'missing bottomButtonBar');
  expect(end, greaterThan(bottom), reason: 'missing bottomButtonBar end');
  return mobileBody.substring(bottom, end);
}
