import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-697（TODO-1378）：视频全屏路由内手柄只有 B 可用、A/D-pad 静默 no-op 的
/// **页面接线**源码守卫。
///
/// 全屏是推到根 navigator 的独立路由，窗口侧 build() 外层的手柄输入层
/// _wrapVideoGamepadControls 不是这棵子树的祖先——修复 = 全屏路由 pageBuilder 的
/// 内容包进**同一个** wrapper，让两个表面共享一份手柄语义（不在 gamepad_service
/// 里加全屏特判）。真实页面无法 headless 加载（无 libmpv），机制本身由
/// video_fullscreen_gamepad_dispatch_test.dart 的同构 harness 行为测试覆盖；本文件
/// 锁死页面两处接线不被后续重构悄悄拆掉。
void main() {
  final String fullscreenPart = File(
    'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final String mainShell = File(
    'lib/src/pages/implementations/video_fushi_page.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  test('全屏路由 pageBuilder 内容必须包进 _wrapVideoGamepadControls（BUG-697）', () {
    final String fn = _slice(
      fullscreenPart,
      '  Future<void> _pushNeutralizedVideoFullscreen(BuildContext context) async {',
      '  void _onVideoFullscreenRouteClosed() {',
    );
    expect(
      fn,
      contains('pageBuilder: (_, __, ___) => _wrapVideoGamepadControls('),
      reason: '全屏路由子树必须持有与窗口模式同一个 GamepadButtonIntent 处理层，'
          '否则桌面手柄轮询以 primaryFocus 为派发起点时 A/D-pad 在全屏内静默 no-op'
          '（BUG-697 根因）。若重构改了包裹方式，请保证等价的 Actions 仍是全屏'
          '子树祖先，并同步更新本守卫与 video_fullscreen_gamepad_dispatch_test。',
    );
  });

  test('窗口模式 build() 仍由 _wrapVideoGamepadControls 包住整页（两表面共享一份语义）', () {
    expect(
      mainShell,
      contains('return _wrapVideoGamepadControls('),
      reason: '窗口侧手柄输入层被拆掉会让 TODO-1342 的整套视频手柄映射失效',
    );
    // wrapper 本体仍把 GamepadButtonIntent 派发到注册表解析入口（两表面共用）。
    final String wrapper = _slice(
      mainShell,
      '  Widget _wrapVideoGamepadControls(Widget child) {',
      '  /// media_kit 桌面控制主题。',
    );
    expect(wrapper, contains('GamepadButtonIntent'));
    expect(wrapper, contains('_handleVideoGamepadButton(intent.button)'));
  });
}

String _slice(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
