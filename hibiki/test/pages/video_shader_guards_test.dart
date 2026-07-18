import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';

import 'video_hibiki_page_source_corpus.dart';

/// video_shader 组合并守卫（守卫审计合并产物）：
/// - 着色器对比原画：原 video_shader_compare_guard_test.dart 并入，断言逐字搬运；
/// - 手机端抑制 Anime4K 首次提示：原 video_shader_prompt_mobile_gate_guard_test.dart
///   并入，断言逐字搬运。
/// （同组 video_shader_mpv_dir_guard_test.dart 经对抗核查维持独立文件，未并入。）
///
/// ── 着色器对比 ──
/// B（缺效果预览/对比）source guard: 视频页接「着色器对比原画」——经 `C` 快捷键切换
/// controller 的旁路态（保留启用集）。
///
/// TODO-127：对比按钮先移出控制条（顶栏只放最常直接命中的入口；着色器对比属配置类
/// 操作）。
/// BUG-261：进一步把对比项从**右键菜单**也移除（用户要求），现只走 `C` 快捷键 / 设置页
/// 进入。`_toggleShaderCompare` 逻辑与 `C` 快捷键接线保留——控制条与右键菜单都不再含
/// 该按钮 / 项。
///
/// ── 手机端抑制 Anime4K 首次提示（TODO-874）──
/// 不变式：[_showAnime4kFirstUsePromptIfNeeded] 方法体最开头必须有移动端
/// （Android / iOS）的 early-return，纯抑制提示。代码自身的
/// `video_shader_mobile_perf_hint` 文案警告手机超分掉帧、发热，再主动劝用户开启
/// 自相矛盾；故手机端整段提示直接跳过，仅桌面端保留。
///
/// 用源码扫描而非整页 widget pump：该提示路径深埋在 HomeVideoPage 的 _open /
/// _openRemote 导航里，依赖完整 AppModel + DB + 远端客户端，整页启动成本高且脆弱；
/// 平台 early-return 这条不变式正是本次需求的精确正面，源码扫描足以守住（与
/// video_experimental_markers_guard_test 同范式）。
String _read(String relative) {
  final File f = File(relative);
  if (!f.existsSync()) {
    throw StateError(
        'missing source: $relative (cwd=${Directory.current.path})');
  }
  return f.readAsStringSync();
}

/// 截取 [_showAnime4kFirstUsePromptIfNeeded] 方法体到下一个方法声明之间的源码切片，
/// 确保断言落在该方法范围内而非文件别处。
String _promptMethodBody(String src) {
  const String marker =
      'Future<void> _showAnime4kFirstUsePromptIfNeeded() async {';
  final int start = src.indexOf(marker);
  expect(start, greaterThan(0),
      reason: '应存在 _showAnime4kFirstUsePromptIfNeeded 方法');
  // 下一个方法是 _downloadAndEnableDefaultShaderTier；切到它为止。
  final int end =
      src.indexOf('_downloadAndEnableDefaultShaderTier', start + marker.length);
  expect(end, greaterThan(start),
      reason: '应能定位方法体边界（下一方法 _downloadAndEnableDefaultShaderTier）');
  return src.substring(start, end);
}

void main() {
  group('着色器对比原画（TODO-127 / BUG-261 / C 快捷键）', () {
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
  });

  group('TODO-874：手机端抑制 Anime4K 首次提示', () {
    final String videoSrc =
        _read('lib/src/pages/implementations/home_video_page.dart');

    test('引入 foundation（defaultTargetPlatform / TargetPlatform）', () {
      expect(videoSrc.contains("import 'package:flutter/foundation.dart';"),
          isTrue,
          reason: '平台门控需要 defaultTargetPlatform，须引 foundation');
    });

    test('方法体内含移动端平台 early-return', () {
      final String body = _promptMethodBody(videoSrc);
      expect(body.contains('defaultTargetPlatform == TargetPlatform.android'),
          isTrue,
          reason: 'Android 应在该方法内被门控早退');
      expect(
          body.contains('defaultTargetPlatform == TargetPlatform.iOS'), isTrue,
          reason: 'iOS 应在该方法内被门控早退');
      // 平台判定后紧跟 return，构成 early-return（移动端直接跳过整段提示）。
      final int iosAt =
          body.indexOf('defaultTargetPlatform == TargetPlatform.iOS');
      final int returnAt = body.indexOf('return;', iosAt);
      expect(returnAt, greaterThan(iosAt),
          reason: '移动端平台判定后应紧跟 return（early-return 抑制提示）');
    });

    test('纯抑制：不在移动端早退路径置 videoAnime4kPromptShown 标记', () {
      final String body = _promptMethodBody(videoSrc);
      final int iosAt =
          body.indexOf('defaultTargetPlatform == TargetPlatform.iOS');
      final int returnAt = body.indexOf('return;', iosAt);
      final String gateSlice = body.substring(0, returnAt);
      expect(gateSlice.contains('setVideoAnime4kPromptShown'), isFalse,
          reason: '移动端为纯抑制，不应在早退前置位（保持零副作用，桌面端仍能首弹）');
    });
  });
}
