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

  group('小窗 chrome 只认显式唤出（用户 2026-09-22：常态只留字幕，别太乱）', () {
    const Map<String, String> builders = <String, String>{
      '顶部拖动带': 'Widget _buildMiniWindowTopChrome()',
      '居中三键':
          'Widget _buildMiniWindowCenterControls(VideoPlayerController controller)',
    };
    builders.forEach((String what, String signature) {
      test('$what 同时订阅唤出位与控制条可见性，判据带 surface', () {
        final String body = methodBody(miniPart, signature);
        final String flat = body.replaceAll(RegExp(r'\s+'), '');
        expect(flat, contains('Listenable.merge('),
            reason: '两个输入缺一不可：桌面小窗只认显式唤出，常规窗口被挤窄到 mini 档'
                '（surface none）时跟 hover 走——后者 media_kit 那层已整套关掉，'
                '三键是画面上唯一的控件，只认快捷键会让鼠标用户一个按钮都看不到');
        expect(flat, contains('_miniChromeRevealed,_videoControlsVisible,'),
            reason: '只订阅其一：另一个输入变了 builder 不重跑，画面停在旧态');
        expect(flat, contains('surface:_miniWindowSurface,'),
            reason: '判据不带 surface 就分不清桌面小窗与常规窄窗口');
        expect(body, contains('videoMiniChromeVisible('),
            reason: '判据走共享纯函数（页面与测试同源），不许在页面里另写一套 if');
        expect(body, isNot(contains('valueListenable: _miniChromeRevealed')),
            reason: '单订阅唤出位的旧形态：常规窄窗口 hover 唤不出 chrome');
      });
    });

    test('非桌面小窗按下去是 no-op（不留一个没人读的标志位）', () {
      final String body = methodBody(miniPart, 'void _toggleMiniChrome()');
      expect(
          body,
          contains(
              'if (_miniWindowSurface != VideoMiniSurface.desktopMiniWindow) '
              'return'),
          reason: '常规窗口（含被挤窄到 mini 档的）chrome 跟 hover、系统画中画归'
              '系统；在那里翻标志位会让下次进小窗带着上一次在主窗按出来的状态。'
              '门只看 showCenterTransport 是不够的：常规窄窗口它也为 true');
    });

    test('顶部带（拖动入口 + 退出钮）只在桌面小窗表面画', () {
      final String flat =
          methodBody(miniPart, 'Widget _buildMiniWindowTopChrome()')
              .replaceAll(RegExp(r'\s+'), '');
      expect(
          flat,
          contains('if(_miniWindowSurface!=VideoMiniSurface.desktopMiniWindow)'
              '{returnconstSizedBox.shrink();}'),
          reason: '常规窗口被挤窄到 mini 档时也解出 showCenterTransport；那时这条带'
              '只剩没用的渐变 + 拖窗手柄，退出钮还是死的（_exitVideoMiniWindow 因'
              ' surface≠desktopMiniWindow 早退）');
    });

    test('进小窗引导性亮一次、退小窗复位', () {
      expect(methodBody(miniPart, 'Future<void> _enterVideoMiniWindow()'),
          contains('_revealMiniChromeBriefly()'),
          reason: '无边框小窗没有系统标题栏：第一次进来一个 chrome 都不出现，用户'
              '看不到退出钮也找不到拖动带');
      expect(methodBody(miniPart, 'Future<void> _exitVideoMiniWindow()'),
          contains('_resetMiniChrome()'),
          reason: '不复位的话下次进小窗直接带着 chrome，常态清爽就没了');
    });
  });
}
