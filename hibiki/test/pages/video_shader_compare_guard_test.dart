import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';

/// B（缺效果预览/对比）source guard: 视频页接「着色器对比原画」——`C` 快捷键 + 右键
/// 菜单项（仅有启用着色器时出现），都切换 controller 的旁路态（保留启用集）。
///
/// TODO-127：对比按钮已移出控制条（顶栏只放最常直接命中的入口；着色器对比属配置类
/// 操作，改从右键菜单 / 快捷键 / 设置进入）。`_toggleShaderCompare` 逻辑、`C` 快捷键、
/// 右键菜单项均保留——只删控制条上的那枚按钮。
void main() {
  final String pageSrc =
      File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync();
  final String shortcutsSrc =
      File('lib/src/media/video/video_player_shortcuts.dart')
          .readAsStringSync();

  /// 截出两套 controls 主题方法体（桌面 + 移动），用于断言「控制条里没有对比按钮」。
  String controlsThemes() {
    final int start = pageSrc.indexOf('MaterialDesktopVideoControlsThemeData');
    final int end = pageSrc.indexOf('void _showTrackMenu(');
    expect(start, greaterThanOrEqualTo(0), reason: '需有桌面 controls 主题');
    expect(end, greaterThan(start),
        reason: '需有 _showTrackMenu 作为 controls 段终点');
    return pageSrc.substring(start, end);
  }

  test('有 _toggleShaderCompare 走 controller.toggleShaderBypass + OSD', () {
    final int start =
        pageSrc.indexOf('Future<void> _toggleShaderCompare() async {');
    expect(start, greaterThanOrEqualTo(0), reason: '需有 _toggleShaderCompare');
    final String body = pageSrc.substring(start, start + 600);
    expect(body.contains('toggleShaderBypass()'), isTrue,
        reason: '对比走 controller.toggleShaderBypass（保留启用集，仅切旁路）');
    expect(body.contains('_showOsd('), isTrue, reason: '对比切换有 OSD 提示当前态');
  });

  test('控制条不再放着色器对比按钮（TODO-127；改从右键菜单 / 快捷键 / 设置进入）', () {
    final String controls = controlsThemes();
    expect(controls.contains('Icons.compare'), isFalse,
        reason: '对比按钮应已移出桌面 / 移动控制条');
    expect(controls.contains('onPressed: _toggleShaderCompare'), isFalse,
        reason: '控制条不应再直接挂 _toggleShaderCompare 按钮');
  });

  test('右键菜单仍在启用着色器时提供对比项（保留可达性）', () {
    expect(pageSrc.contains('if (_hasShadersEnabled)'), isTrue,
        reason: '对比项按是否配置启用着色器条件显示');
    expect(pageSrc.contains('Icons.compare'), isTrue,
        reason: '对比项仍用 compare 图标（右键菜单）');
    expect(
        pageSrc.contains('decodeEnabledShaders(appModel.videoShadersEnabled)'),
        isTrue,
        reason: '_hasShadersEnabled 由启用集解码判定');
  });

  test('C 快捷键切换着色器对比', () {
    // TODO-134: video keys live in the remappable registry now. The page
    // delegates to buildVideoPlayerShortcutsFromRegistry; the C-key default
    // is in shortcut_defaults.dart (videoToggleShaderCompare); the
    // action->callback wiring is in video_player_shortcuts.dart.
    expect(pageSrc.contains('buildVideoPlayerShortcutsFromRegistry('), isTrue,
        reason: 'page delegates to the shared registry-backed builder');
    expect(
        pageSrc.contains(
          'toggleShaderCompare: () => unawaited(_toggleShaderCompare())',
        ),
        isTrue,
        reason: 'page shortcut action runs _toggleShaderCompare');
    const InputBinding cKey = InputBinding(key: LogicalKeyboardKey.keyC);
    expect(
        ShortcutDefaults.forPlatform(TargetPlatform.windows)[
                ShortcutAction.videoToggleShaderCompare]!
            .keyboardBindings
            .contains(cKey),
        isTrue,
        reason: 'C is the default key for videoToggleShaderCompare');
    expect(
        shortcutsSrc.contains('ShortcutAction.videoToggleShaderCompare: '
            'actions.toggleShaderCompare'),
        isTrue,
        reason: 'C action wired to toggleShaderCompare');
  });
}
