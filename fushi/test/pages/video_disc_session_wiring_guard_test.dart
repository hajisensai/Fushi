// 源码接线守卫（BD/DVD 原盘交互改造第 6 / 7 项）：原盘会话的点击层级、Esc / 手柄 B
// 的短按与按住退出、返回链的「先呼出控制栏」都在超大视频页里，行为测试要起真播放器，
// 判据本身由 test/media/video/disc/disc_session_controls_test.dart 覆盖，这里钉接线。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _member(String source, String start) {
  final int at = source.indexOf(start);
  expect(at, isNonNegative, reason: 'missing: $start');
  final RegExp next = RegExp(r'\n  (?:[A-Za-z_<]|///)');
  final Match? end = next.firstMatch(source.substring(at + start.length));
  return end == null
      ? source.substring(at)
      : source.substring(at, at + start.length + end.start);
}

void main() {
  final String part = _read(
    'lib/src/pages/implementations/video_fushi/disc_menu.part.dart',
  );

  test('surface taps: page layers first, then the shared layer rule', () {
    final String body = _member(part, 'Future<void> _onDiscSurfaceTap(');
    final int layers = body.indexOf('_dismissTopForegroundLayer()');
    final int rule = body.indexOf('resolveDiscSurfaceTap(');
    expect(layers, isNonNegative);
    expect(rule, greaterThan(layers), reason: '先关页面浮层，这一下不再做别的');
    expect(body, contains('overlayOpen: _discMenuChromeVisible.value'));
    // 盘是否接收由命令结果决定（第 0 步实测），未接收才按空白处理。
    expect(body, contains('_clickDiscMenu(controller, point)'));
    expect(body, contains('resolveUnconsumedDiscClick('));
  });

  test('Esc and gamepad B are session keys with hold-to-exit', () {
    final String key = _member(part, 'bool _handleDiscMenuKey(KeyEvent event)');
    expect(key, contains('LogicalKeyboardKey.escape'));
    expect(key, contains('_handleDiscExitHoldEdge(event'));
    final String pad = _member(
      part,
      'bool _handleDiscMenuGamepad(GamepadButton button)',
    );
    expect(pad, contains('_discExitHold.press(GamepadButton.b)'));
    expect(
      _read('lib/src/pages/implementations/video_fushi_page.dart'),
      contains('_handleDiscMenuGamepadRelease(button) ||'),
      reason: '手柄 B 的松开沿决定短按还是已按满',
    );
  });

  test('back summons the bar before leaving, in window and fullscreen', () {
    final String page = _read(
      'lib/src/pages/implementations/video_fushi_page.dart',
    );
    final String back = _member(page, 'Future<void> _handleBackOrExit() async');
    expect(
      back.indexOf('_discSessionShowBarOnBack()'),
      greaterThan(back.indexOf('_dismissTopForegroundLayer()')),
    );
    final String fullscreen = _read(
      'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
    );
    expect(fullscreen, contains('_discSessionShowBarOnBack(),'));
    expect(
      _member(fullscreen, 'void _exitVideoFullscreenOnBack()'),
      contains('_exitDiscSession()'),
    );
  });
}
