import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：视频播放设置面板已从 bespoke 深色单列 `showModalBottomSheet` 迁移到与阅读器
/// 同款 master-detail（`VideoQuickSettingsSheet` + 桌面 `HibikiDialogFrame(900)` /
/// 移动 `adaptiveModalSheet`）。防回归退回旧的黑底单列 StatefulBuilder/ChoiceChip。
String _between(String source, String start, String end) {
  final int s = source.indexOf(start);
  expect(s, isNonNegative, reason: 'missing marker: $start');
  final int e = source.indexOf(end, s);
  expect(e, isNonNegative, reason: 'missing marker: $end');
  return source.substring(s, e);
}

void main() {
  test('video player settings uses the shared master-detail sheet', () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();
    final String method = _between(
      source,
      'void _showPlayerSettings() {',
      '_showSubtitleSourceMenu(',
    );

    // 用共享面板 + 与阅读器一致的呈现（桌面分栏宽画布 / 移动 bottom sheet）。
    expect(method, contains('VideoQuickSettingsSheet('));
    expect(method, contains('HibikiDialogFrame('));
    expect(method, contains('maxWidth: 900'));
    expect(method, contains('scrollable: false'));
    expect(method, contains('adaptiveModalSheet<void>('));
    expect(method, contains('isDesktopPlatform'));

    // 着色器/mpv 配置改为面板内嵌：构造面板时直接喂初值 + 内嵌回调，不再弹独立对话框。
    expect(method, contains('initialShadersEnabled:'));
    expect(method, contains('onApplyShaders:'));
    expect(method, contains('initialMpvConfig:'));
    expect(method, contains('onMpvConfigChanged:'));
    expect(method, contains('initialLockWindowAspectRatio:'));
    expect(method, contains('onLockWindowAspectRatioChanged:'));
    expect(method, contains('initialAsbConfig:'));
    expect(method, contains('onAsbConfigChanged:'));
    expect(method, contains('onSubtitleOffsetChanged:'));

    // 旧 bespoke 深色单列面板已移除（防回归）。
    expect(method, isNot(contains('showModalBottomSheet')),
        reason: '播放设置不再走 bespoke bottom sheet');
    expect(method, isNot(contains('Colors.black87')));
    expect(method, isNot(contains('StatefulBuilder')));
    expect(method, isNot(contains('ChoiceChip')));

    // 着色器/mpv 不再弹独立对话框（防回归到旧的 pop 面板 + 二级对话框）。
    expect(source, isNot(contains('_openShaderDialog')),
        reason: '着色器改为面板内嵌，不再有独立对话框方法');
    expect(source, isNot(contains('_openMpvConfigDialog')),
        reason: 'mpv 配置改为面板内嵌，不再有独立对话框方法');
    expect(source, isNot(contains('VideoShaderDialog(')),
        reason: '着色器改用内嵌 VideoShaderManagerView');
  });

  test('VideoQuickSettingsSheet mirrors the reader master-detail skeleton', () {
    final String source =
        File('lib/src/media/video/video_quick_settings_sheet.dart')
            .readAsStringSync();

    expect(source, contains('class VideoQuickSettingsSheet'));
    // 与阅读器同源的「不套外层滚动 + 宽窗撑满有界高度」范式（BUG-096）。
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('scrollable: false'));
    expect(source, contains('MaterialSupportingPaneLayout('));
    expect(source, contains('minSplitWidth: kHibikiSettingsWideThreshold'));
    // 左父菜单收窄到共享常量（旧硬编码 248）。
    expect(source,
        contains('supportingWidth: kHibikiSettingsSupportingPaneWidth'));
    expect(source, contains('SupportingPaneSide.start'));
    expect(source, contains('height: constraints.maxHeight'));
    // 确定性几何判据：宽且高都 >= 共享常量阈值才进宽窗（与书籍设置同条件）。
    expect(source,
        contains('constraints.maxWidth >= kHibikiSettingsWideThreshold'));
    expect(source,
        contains('constraints.maxHeight >= kHibikiSettingsWideMinHeight'));
    // 旧的「post-frame 测内容溢出回退」已移除（会随内容高度发散 → 同设备两种表现）。
    expect(source, isNot(contains('_supportingOverflowsWide')));
    expect(source, isNot(contains('_supportingScrollController')));
    expect(source, contains('padding: wideSupportingPadding'));
    expect(source, contains('padding: widePrimaryPadding'));
    // 左父菜单单选高亮（pill），无 chevron 误导 push。
    expect(source, contains('HibikiListItemSelectedShape.pill'));
    // 右 pane 按选中 id KeyedSubtree，防 Element 复用副作用。
    expect(source, contains('KeyedSubtree('));
    expect(source, contains("_subPage ?? 'playback'"));
    // 四个分类齐全。
    for (final String id in <String>[
      "id: 'playback'",
      "id: 'shaders'",
      "id: 'mpv'",
      "id: 'subtitle'",
    ]) {
      expect(source, contains(id), reason: 'missing category $id');
    }

    // 着色器/mpv 详情改为面板内嵌（不再用 NavigationRow pop 面板再弹对话框）。
    expect(source, contains('VideoShaderManagerView('),
        reason: '着色器详情内嵌 VideoShaderManagerView');
    expect(source, contains('AdaptiveSettingsPickerRow<String>('),
        reason: 'mpv 配置内嵌成 AdaptiveSettings 行（hwdec/aspect/channels 用 picker）');
    expect(source, contains('VideoMpvConfig.defaults'),
        reason: 'mpv 内嵌详情含「重置默认」');
    expect(source, contains('initialLockWindowAspectRatio'));
    expect(source, contains('onLockWindowAspectRatioChanged'));
    expect(source, contains('isDesktopPlatform'));
    expect(source, contains('t.video_setting_mpv_aspect'));
    expect(source, contains('initialAsbConfig'));
    expect(source, contains('onAsbConfigChanged'));
    expect(source, contains('onSubtitleOffsetChanged'));
    expect(source, contains('pauseAtSubtitleEnd'));
    expect(source, contains('AdaptiveSettingsStepperRow'));
    expect(source, isNot(contains('widget.onOpenShaders')));
    expect(source, isNot(contains('widget.onOpenMpvConfig')));
  });

  test('shader manager is grouped instead of a flat action button pile', () {
    final String source =
        File('lib/src/pages/implementations/video_shader_dialog.dart')
            .readAsStringSync();
    final String buildMethod = _between(
      source,
      '  @override\n  Widget build(BuildContext context) {',
      '/// 从本机 mpv 发现的着色器多选导入对话框',
    );

    expect(buildMethod, contains('AdaptiveSettingsSection('),
        reason: '着色器详情应按画质增强 / 模板 / 导入 / 列表分组');
    expect(buildMethod, contains('video_shader_section_templates'));
    expect(buildMethod, contains('video_shader_section_import'));
    expect(buildMethod, contains('video_shader_section_installed'));
    expect(buildMethod, isNot(contains('Wrap(')),
        reason: '不能把下载/导入动作作为六个同级按钮堆在顶部');
  });
}
