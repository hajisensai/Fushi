import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';

import 'video_hibiki_page_source_corpus.dart';

/// B（缺效果预览/对比）source guard: 视频页接「着色器对比原画」——经 `C` 快捷键切换
/// controller 的旁路态（保留启用集）。
///
/// TODO-127：对比按钮先移出控制条（顶栏只放最常直接命中的入口；着色器对比属配置类
/// 操作）。
/// BUG-261：进一步把对比项从**右键菜单**也移除（用户要求），现只走 `C` 快捷键 / 设置页
/// 进入。`_toggleShaderCompare` 逻辑与 `C` 快捷键接线保留——控制条与右键菜单都不再含
/// 该按钮 / 项。
void main() {
  // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，读「合并语料」
  // （主壳 + 全部 part）才能命中它们；整页级断言命中的 _toggleShaderCompare / 右键菜单 /
  // 快捷键接线仍在主壳，合并语料仍覆盖。
  final String pageSrc = readVideoHibikiSource();
  final String shortcutsSrc =
      File('lib/src/media/video/video_player_shortcuts.dart')
          .readAsStringSync();

  /// 截出两套 controls 主题方法体（桌面 + 移动），用于断言「控制条里没有对比按钮」。
  String controlsThemes() {
    // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart（合并语料末段，
    // _desktopControlsTheme 紧接 _mobileControlsTheme）。起点用桌面主题**完整签名**（避免命中
    // 主壳里 `MaterialDesktopVideoControlsThemeData` 的注释 / 类型引用），终点用 part 顶格
    // extension 闭合 `\n}`——它紧随末方法 _mobileControlsTheme，恰夹住两套 controls 主题。
    final int start = pageSrc.indexOf(
        'MaterialDesktopVideoControlsThemeData _desktopControlsTheme(');
    final int end = pageSrc.indexOf('\n}', start);
    expect(start, greaterThanOrEqualTo(0), reason: '需有桌面 controls 主题');
    expect(end, greaterThan(start),
        reason: '需有 part 顶格 extension 闭合作为 controls 段终点');
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

  test('右键菜单不再含着色器对比项（BUG-261；改走 C 快捷键 / 设置）', () {
    // 整页源码（含控制条与右键菜单）都不应再出现 compare 图标——对比项已两处皆删。
    expect(pageSrc.contains('Icons.compare'), isFalse,
        reason: '着色器对比项已从右键菜单移除（BUG-261），控制条早已无（TODO-127）');
    // 右键菜单不再依赖「是否启用着色器」的门控（原 _hasShadersEnabled getter 随该项移除）。
    expect(pageSrc.contains('if (_hasShadersEnabled)'), isFalse,
        reason: '右键不再按启用着色器条件显示对比项（_hasShadersEnabled 已移除）');
  });

  test('C 快捷键切换着色器对比', () {
    // TODO-134: video keys live in the remappable registry now. The page
    // delegates to buildVideoPlayerShortcutsFromRegistry; the C-key default
    // is in shortcut_defaults.dart (videoToggleShaderCompare); the
    // action->callback wiring is in video_player_shortcuts.dart.
    expect(pageSrc.contains('buildVideoPlayerShortcutsFromRegistry('), isTrue,
        reason: 'page delegates to the shared registry-backed builder');
    final int actionIdx = pageSrc.indexOf('toggleShaderCompare:');
    expect(actionIdx, greaterThanOrEqualTo(0),
        reason: 'page must provide toggleShaderCompare action');
    final int nextActionIdx = pageSrc.indexOf('volumeUp:', actionIdx);
    expect(nextActionIdx, greaterThan(actionIdx),
        reason: 'toggleShaderCompare callback must end before volumeUp');
    final String callback = pageSrc.substring(actionIdx, nextActionIdx);
    final int gate = callback.indexOf('_runWhenImmersiveAllowsFullControls');
    final int toggle = callback.indexOf('_toggleShaderCompare()');
    expect(gate, greaterThanOrEqualTo(0),
        reason: 'C shortcut must respect the full-controls immersive gate');
    expect(toggle, greaterThan(gate),
        reason: 'C shortcut action runs _toggleShaderCompare after the gate');
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
