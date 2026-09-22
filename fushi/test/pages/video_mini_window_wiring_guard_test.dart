import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 桌面小窗的三条接线不变式（PR #1596 审查）。都是「结构上写错了本地和 CI 全绿、
/// 真机才翻车」的那种，所以钉在源码层。
void main() {
  final String miniPart = maskComments(
    File(
      'lib/src/pages/implementations/video_fushi/mini_window.part.dart',
    ).readAsStringSync(),
  );
  final String fullscreenPart = maskComments(
    File(
      'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
    ).readAsStringSync(),
  );

  test('小窗拖动带不用 DragToMoveArea（它自带双击最大化）', () {
    expect(miniPart, isNot(contains('DragToMoveArea(')),
        reason: 'window_manager 的 DragToMoveArea 双击 → maximize()：置顶无边框的小窗'
            '被最大化成铺满整屏的 mini chrome，退出再对最大化态 setBounds 得到畸形态');
    expect(miniPart, contains('windowManager.startDragging()'),
        reason: '只要拖动，不要双击');
  });

  test('小窗里切全屏先退小窗（全屏与小窗互斥的另一个方向）', () {
    final String body = methodBody(
      fullscreenPart,
      'Future<void> _toggleVideoFullscreen(BuildContext context)',
    );
    expect(body, contains('_exitVideoMiniWindow()'),
        reason: 'enter 只做了「进小窗先退全屏」；小窗里按 F11 不先退小窗，runner 全屏'
            '会叠在小窗态之上，密度判据恒回 mini');
  });

  test('新页 initState 认领上一集留下的小窗（换集不弹回主窗）', () {
    final String body = methodBody(miniPart, 'void _initMiniWindowSupport()');
    expect(body, contains('DesktopMiniWindowMode.claim(owner: this)'),
        reason: '本地换集 pushReplacement 旧页 dispose 晚于新页 initState；不认领，旧页'
            '的 exit 会把小窗退掉——每换一集（含自动连播）小窗都弹回主窗');
  });
}
