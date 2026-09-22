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
      test('$what 订阅 _miniChromeRevealed、不订阅控制条可见性', () {
        final String body = methodBody(miniPart, signature);
        expect(body, contains('valueListenable: _miniChromeRevealed'),
            reason: '显隐的唯一驱动是显式唤出（快捷键 / 进小窗那次引导）');
        expect(body, isNot(contains('_videoControlsVisible')),
            reason: '一旦订阅回控制条可见性，鼠标扫过小窗就又会弹出一层按钮——'
                '那正是本次要去掉的「太乱」');
        expect(body, contains('videoMiniChromeVisible('),
            reason: '判据走共享纯函数（页面与测试同源），不许在页面里另写一套 if');
      });
    });

    test('非自绘档按下去是 no-op（不留一个没人读的标志位）', () {
      final String body = methodBody(miniPart, 'void _toggleMiniChrome()');
      expect(body, contains('if (!_controlsDensity.showCenterTransport) return'),
          reason: '常规窗口 chrome 归 media_kit、系统画中画归系统；在那里翻标志位'
              '会让下次进小窗带着上一次在主窗按出来的状态');
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
