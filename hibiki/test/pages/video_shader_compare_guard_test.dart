import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// B（缺效果预览/对比）source guard: 视频页接「着色器对比原画」——桌面控制条对比
/// 按钮（仅有启用着色器时出现）+ `C` 快捷键，都切换 controller 的旁路态（保留启用集）。
/// 着色器仅桌面 libmpv 生效，故对比按钮只在桌面控制条。
void main() {
  final String src =
      File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync();

  test('有 _toggleShaderCompare 走 controller.toggleShaderBypass + OSD', () {
    final int start =
        src.indexOf('Future<void> _toggleShaderCompare() async {');
    expect(start, greaterThanOrEqualTo(0), reason: '需有 _toggleShaderCompare');
    final String body = src.substring(start, start + 600);
    expect(body.contains('toggleShaderBypass()'), isTrue,
        reason: '对比走 controller.toggleShaderBypass（保留启用集，仅切旁路）');
    expect(body.contains('_showOsd('), isTrue, reason: '对比切换有 OSD 提示当前态');
  });

  test('桌面控制条仅在有启用着色器时显示对比按钮', () {
    expect(src.contains('if (_hasShadersEnabled)'), isTrue,
        reason: '对比按钮按是否配置启用着色器条件显示');
    expect(src.contains('Icons.compare'), isTrue, reason: '对比按钮用 compare 图标');
    expect(src.contains('decodeEnabledShaders(appModel.videoShadersEnabled)'),
        isTrue,
        reason: '_hasShadersEnabled 由启用集解码判定');
  });

  test('C 快捷键切换着色器对比', () {
    expect(src.contains('LogicalKeyboardKey.keyC'), isTrue,
        reason: 'C 键绑定着色器对比');
    final int k = src.indexOf('LogicalKeyboardKey.keyC');
    expect(src.substring(k, k + 120).contains('_toggleShaderCompare()'), isTrue,
        reason: 'C 键走 _toggleShaderCompare');
  });
}
