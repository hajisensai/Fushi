import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// B（缺效果预览/对比）source guard: 视频页接「着色器对比原画」——桌面控制条对比
/// 按钮（仅有启用着色器时出现）+ `C` 快捷键，都切换 controller 的旁路态（保留启用集）。
/// 着色器仅桌面 libmpv 生效，故对比按钮只在桌面控制条。
void main() {
  final String pageSrc =
      File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync();
  final String shortcutsSrc =
      File('lib/src/media/video/video_player_shortcuts.dart')
          .readAsStringSync();

  test('有 _toggleShaderCompare 走 controller.toggleShaderBypass + OSD', () {
    final int start =
        pageSrc.indexOf('Future<void> _toggleShaderCompare() async {');
    expect(start, greaterThanOrEqualTo(0), reason: '需有 _toggleShaderCompare');
    final String body = pageSrc.substring(start, start + 600);
    expect(body.contains('toggleShaderBypass()'), isTrue,
        reason: '对比走 controller.toggleShaderBypass（保留启用集，仅切旁路）');
    expect(body.contains('_showOsd('), isTrue, reason: '对比切换有 OSD 提示当前态');
  });

  test('桌面控制条仅在有启用着色器时显示对比按钮', () {
    expect(pageSrc.contains('if (_hasShadersEnabled)'), isTrue,
        reason: '对比按钮按是否配置启用着色器条件显示');
    expect(pageSrc.contains('Icons.compare'), isTrue,
        reason: '对比按钮用 compare 图标');
    expect(
        pageSrc.contains('decodeEnabledShaders(appModel.videoShadersEnabled)'),
        isTrue,
        reason: '_hasShadersEnabled 由启用集解码判定');
  });

  test('C 快捷键切换着色器对比', () {
    expect(pageSrc.contains('buildVideoPlayerShortcuts('), isTrue,
        reason: '视频页应委托共用快捷键构建器');
    expect(
        pageSrc.contains(
          'toggleShaderCompare: () => unawaited(_toggleShaderCompare())',
        ),
        isTrue,
        reason: '页面 shortcut action 应走 _toggleShaderCompare');
    expect(shortcutsSrc.contains('LogicalKeyboardKey.keyC'), isTrue,
        reason: 'C 键绑定着色器对比');
    final int k = shortcutsSrc.indexOf('LogicalKeyboardKey.keyC');
    expect(
        shortcutsSrc
            .substring(k, k + 120)
            .contains('actions.toggleShaderCompare'),
        isTrue,
        reason: 'C 键走 toggleShaderCompare action');
  });
}
