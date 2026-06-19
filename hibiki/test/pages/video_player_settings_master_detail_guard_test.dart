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

String _member(String source, String start) {
  final int s = source.indexOf(start);
  expect(s, isNonNegative, reason: 'missing marker: $start');
  final List<int> ends = <int>[
    source.indexOf('\n  Widget ', s + start.length),
    source.indexOf('\n  Future', s + start.length),
    source.indexOf('\n  void ', s + start.length),
    source.indexOf('\n  Alignment ', s + start.length),
    source.indexOf('\n  String ', s + start.length),
    source.indexOf('\n  bool ', s + start.length),
  ].where((int i) => i > s).toList();
  final int e = ends.isEmpty
      ? source.length
      : ends.reduce((int a, int b) => a < b ? a : b);
  return source.substring(s, e);
}

void main() {
  test('video player settings uses the shared master-detail sheet', () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();
    final String showMethod = _member(
      source,
      'void _showPlayerSettings(',
    );
    final String buildMethod = _between(
      source,
      'Widget _buildVideoQuickSettingsSheet() {',
      'void _showPlayerSettings(',
    );
    final String panelChildMethod = _between(
      source,
      'Widget _buildVideoSidePanelChild(',
      'Widget _buildVideoSidePanelOverlay(VideoPlayerController controller) {',
    );

    // 用统一半透明侧栏承载共享面板；面板内部仍按宽度决定 master-detail / push。
    expect(showMethod, contains('_VideoSidePanelKind.settings'));
    expect(showMethod, contains('sourceSlot: sourceSlot'));
    expect(source, contains('VideoTranslucentSidePanel('));
    expect(panelChildMethod, contains('case _VideoSidePanelKind.settings:'));
    expect(
        panelChildMethod, contains('return _buildVideoQuickSettingsSheet()'));
    expect(buildMethod, contains('VideoQuickSettingsSheet('));

    // 着色器/mpv 配置改为面板内嵌：构造面板时直接喂初值 + 内嵌回调，不再弹独立对话框。
    expect(buildMethod, contains('initialShadersEnabled:'));
    expect(buildMethod, contains('onApplyShaders:'));
    expect(buildMethod, contains('initialMpvConfig:'));
    expect(buildMethod, contains('onMpvConfigChanged:'));
    expect(buildMethod, contains('initialLockWindowAspectRatio:'));
    expect(buildMethod, contains('onLockWindowAspectRatioChanged:'));
    expect(buildMethod, contains('initialAsbConfig:'));
    expect(buildMethod, contains('onAsbConfigChanged:'));
    // TODO-060：字幕调轴经 onSetDelay 绝对提交（滑条/±/输入框三处共享）；
    // 旧的增量 onSubtitleOffsetChanged 已删。
    expect(buildMethod, contains('onSetDelay:'));
    expect(buildMethod, contains('initialDelayMs:'));

    // 旧 bespoke 深色单列面板已移除（防回归）。
    expect(showMethod, isNot(contains('showModalBottomSheet')),
        reason: '播放设置不再走 bespoke bottom sheet');
    expect(buildMethod, isNot(contains('Colors.black87')));
    expect(buildMethod, isNot(contains('StatefulBuilder')));
    expect(buildMethod, isNot(contains('ChoiceChip')));

    // 着色器/mpv 不再弹独立对话框（防回归到旧的 pop 面板 + 二级对话框）。
    expect(source, isNot(contains('_openShaderDialog')),
        reason: '着色器改为面板内嵌，不再有独立对话框方法');
    expect(source, isNot(contains('_openMpvConfigDialog')),
        reason: 'mpv 配置改为面板内嵌，不再有独立对话框方法');
    expect(source, isNot(contains('VideoShaderDialog(')),
        reason: '着色器改用内嵌 VideoShaderManagerView');
  });

  test(
      'VideoQuickSettingsSheet stacks top category chips over the detail '
      '(TODO-556 video-only top bar)', () {
    final String source =
        File('lib/src/media/video/video_quick_settings_sheet.dart')
            .readAsStringSync();

    expect(source, contains('class VideoQuickSettingsSheet'));
    // 与阅读器同源的「不套外层滚动 + 宽窗撑满有界高度」范式（BUG-096）。
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('scrollable: false'));
    expect(source, contains('height: constraints.maxHeight'));
    // 确定性几何判据：宽且高都 >= 共享常量阈值才进宽窗（与书籍设置同条件）。
    expect(source,
        contains('constraints.maxWidth >= kHibikiSettingsWideThreshold'));
    expect(source,
        contains('constraints.maxHeight >= kHibikiSettingsWideMinHeight'));

    // TODO-427-③：宽窗从左右 master-detail（窄左栏 + 右详情）改成顶部横向分类 chip 行 +
    // 下方详情上下分栏，根治窄侧栏左右劈半把右详情挤窄、下拉抢宽裁标题。
    // 旧的左右分栏符号必须删除（防回退）。
    expect(source, isNot(contains('MaterialSupportingPaneLayout(')),
        reason:
            'video settings wide layout must not regress to left master-detail');
    expect(source, isNot(contains('_videoSupportingPaneWidth')),
        reason:
            'video-specific supporting width constants should stay removed');
    expect(source, isNot(contains('_buildWidePane')),
        reason: 'old left-pane builder _buildWidePane must be removed');
    expect(source, isNot(contains('SupportingPaneSide.start')),
        reason: 'video settings must not use a supporting (left) pane anymore');
    expect(source, isNot(contains('_videoSettingsSupportingPaneReadableWidth')),
        reason: 'left supporting-pane width constants must stay removed');
    expect(source, isNot(contains('_videoSettingsSupportingPaneWidth(')),
        reason: 'left supporting-pane width helper must stay removed');
    expect(source, isNot(contains('232,')),
        reason: 'video settings must not regress to the fixed 232px pane');
    expect(source, isNot(contains('HibikiListItem(')),
        reason: 'wide categories must not render as a left list anymore');
    expect(source, contains('_buildTopCategoryBar('),
        reason: 'wide categories must render in a top horizontal chip bar');
    expect(source, contains('HibikiSelectableChip('),
        reason: 'each top-bar category is a selectable chip');
    expect(source, contains('allowLabelOverflow: true'),
        reason: 'top-bar chip labels must stay fully readable, not ellipsized');
    expect(source, contains('scrollDirection: Axis.horizontal'),
        reason: 'the top category bar scrolls horizontally when it overflows');
    expect(source, contains('padding: widePrimaryPadding'));
    // 详情按选中 id KeyedSubtree，防 Element 复用副作用。
    expect(source, contains('KeyedSubtree('));
    expect(source, contains("_subPage ?? 'playback'"));
    // 六个分类齐全（chip 行 + 窄窗导航行共用 _categories）。
    for (final String id in <String>[
      "id: 'playback'",
      "id: 'shaders'",
      "id: 'mpv'",
      "id: 'subtitle'",
      "id: 'danmaku'",
      "id: 'controls'",
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
    expect(source, contains('onSetDelay'));
    expect(source, contains('pauseAtSubtitleEnd'));
    expect(source, contains('AdaptiveSettingsStepperRow'));
    expect(source, isNot(contains('widget.onOpenShaders')));
    expect(source, isNot(contains('widget.onOpenMpvConfig')));
  });

  test('video quick settings groups category and detail section surfaces', () {
    final String source =
        File('lib/src/media/video/video_quick_settings_sheet.dart')
            .readAsStringSync();

    expect(source, contains('Widget _buildTopCategoryBar('),
        reason: 'wide categories render in a top horizontal chip bar');
    expect(source,
        contains('titlePlacement: SettingsSectionTitlePlacement.inside'),
        reason:
            'video detail section headings should be visually part of their group surface');
    expect(
        source,
        isNot(contains(
            'SettingsSectionHeader(t.video_setting_mpv_group_advanced)')),
        reason:
            'mpv advanced heading must not float outside its settings group');
  });

  test('embedded shader detail keeps section titles inside video surfaces', () {
    final String quickSettingsSource =
        File('lib/src/media/video/video_quick_settings_sheet.dart')
            .readAsStringSync();
    final String shaderDetail = _between(
      quickSettingsSource,
      '  Widget _buildShadersDetail() {',
      '  Widget _buildMpvDetail() {',
    );

    expect(shaderDetail, contains('VideoShaderManagerView('),
        reason: 'video settings should embed the shader manager detail');
    expect(
      shaderDetail,
      contains('titlePlacement: SettingsSectionTitlePlacement.inside'),
      reason:
          'embedded shader detail headings must be part of the video section surfaces',
    );

    final String shaderSource =
        File('lib/src/pages/implementations/video_shader_dialog.dart')
            .readAsStringSync();
    final String managerWidget = _between(
      shaderSource,
      'class VideoShaderManagerView extends StatefulWidget {',
      'class _VideoShaderManagerViewState extends State<VideoShaderManagerView> {',
    );
    final String buildMethod = _between(
      shaderSource,
      '  @override\n  Widget build(BuildContext context) {',
      'class _MpvShaderPickerDialog extends StatefulWidget {',
    );
    final int titledShaderSections =
        RegExp(r'AdaptiveSettingsSection\(\s*title:')
            .allMatches(buildMethod)
            .length;
    final int placementForwarders =
        RegExp(r'titlePlacement:\s*widget\.titlePlacement')
            .allMatches(buildMethod)
            .length;

    expect(managerWidget,
        contains('this.titlePlacement = SettingsSectionTitlePlacement.outside'),
        reason:
            'standalone shader manager callers should keep the current outside-title default');
    expect(managerWidget,
        contains('final SettingsSectionTitlePlacement titlePlacement;'));
    expect(titledShaderSections, 3,
        reason:
            'shader detail is expected to expose quality, advanced, and installed sections');
    expect(placementForwarders, titledShaderSections,
        reason:
            'all titled shader sections must honor the caller-selected title placement');
  });

  test('video settings side panel owns UI scale and hover lifetime', () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();
    // TODO-314：字幕列表改 push-aside 后 overlay 版 _buildSubtitleListSidePanel 已删，
    // _buildVideoSidePanelContent 之后直接是 _buildSubtitleSourcesSidePanel。
    final String panelMethod = _between(
      source,
      'Widget _buildVideoSidePanelOverlay(VideoPlayerController controller) {',
      'Widget _buildSubtitleSourcesSidePanel(VideoPlayerController controller) {',
    );
    final String visibilityMethod = _between(
      source,
      'void _markControlsVisible(bool visible) {',
      '/// 桌面鼠标移出视频区',
    );
    final String pokeMethod = _between(
      source,
      'void _pokeControlsVisible() {',
      '/// media_kit 控制条自动隐藏时长',
    );
    final String hoverExitMethod = _between(
      source,
      'void _onVideoControlsHoverExit() {',
      'bool _isSyntheticControlsHover(PointerEvent event)',
    );
    final String syntheticHoverMethod = _between(
      source,
      'bool _isSyntheticControlsHover(PointerEvent event)',
      'void _handleVideoControlsHover(PointerEvent event) {',
    );
    final String hoverHandlerMethod = _between(
      source,
      'void _handleVideoControlsHover(PointerEvent event) {',
      'void _handleVideoControlsHoverExit(PointerEvent event) {',
    );
    final String hoverExitHandlerMethod = _between(
      source,
      'void _handleVideoControlsHoverExit(PointerEvent event) {',
      '/// 唤回视频左侧锁',
    );
    final String hoverWrapMethod = _between(
      source,
      'Widget _videoControlsHoverWrap({required Widget child}) {',
      '/// [_buildVideoControls] 的实体',
    );

    expect(
      panelMethod,
      contains('kind != _VideoSidePanelKind.settings'),
      reason: '只有设置侧栏需要重新吃 app UI scale，避免字幕列表等已经手动缩放的面板二次放大',
    );
    expect(panelMethod, contains('HibikiAppUiScale('));
    expect(panelMethod, contains('scale: _videoUiScale'));
    expect(
        panelMethod, isNot(contains('valueListenable: _videoControlsVisible')),
        reason: '设置侧栏必须独立于控制条自动隐藏，不应随 action rail 一起卸载');

    // TODO-364：poke 仍派合成 hover 驱动 media_kit 自己的可见性/Timer（单一真相源），
    // 但不再另翻 Hibiki 镜像（相位反根因）。
    expect(pokeMethod, contains('device: _syntheticHoverDevice'));
    expect(pokeMethod, isNot(contains('_markControlsVisible(true);')),
        reason: 'poke 不应再乐观翻镜像（可见性由 media_kit 收合成 hover 后推送，TODO-364）');
    // TODO-364：_markControlsVisible 收敛成仅门控收起（assert(!visible)）+ 重派生；
    // 不再有 Hibiki 侧独立隐藏 Timer 条件。
    expect(visibilityMethod, contains('_applyControlsVisibilityFromMediaKit()'),
        reason: '_markControlsVisible 应委托唯一派生函数');
    expect(visibilityMethod, isNot(contains('_videoControlsHideTimer')),
        reason: '不应残留 Hibiki 侧独立隐藏 Timer（TODO-364）');
    // TODO-364：鼠标移出只交还光标，控制条隐藏由 media_kit onExit 推送，不在 Hibiki 侧判可见。
    expect(hoverExitMethod, contains('_setCursorHidden(false)'),
        reason: '鼠标移出应交还光标');
    expect(
        hoverExitMethod, isNot(contains('_videoControlsVisible.value = false')),
        reason: '鼠标移出不应在 Hibiki 侧直接收起可见性（交给 media_kit onExit 推送，TODO-364）');
    expect(syntheticHoverMethod,
        contains('event.device == _syntheticHoverDevice'));
    expect(
        hoverHandlerMethod, contains('if (!_isSyntheticControlsHover(event))'));
    // TODO-364：真实 hover 不再乐观翻镜像（可见性由 media_kit onHover 推送）。
    expect(hoverHandlerMethod, isNot(contains('_markControlsVisible(true);')),
        reason: 'hover 不应再乐观翻镜像（可见性由 media_kit 真实态推送，TODO-364）');
    expect(hoverExitHandlerMethod,
        contains('if (_isSyntheticControlsHover(event)) return;'));
    expect(hoverExitHandlerMethod, contains('_onVideoControlsHoverExit();'));
    expect(hoverWrapMethod, contains('onEnter: _handleVideoControlsHover'));
    expect(hoverWrapMethod, contains('onHover: _handleVideoControlsHover'));
    expect(hoverWrapMethod, contains('onExit: _handleVideoControlsHoverExit'));
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
        reason: '着色器详情应按画质档位 / 进阶 / 列表分组');
    // TODO-041 方案甲'：顶部是五档单选器（无/低/中/高/极高），不再一堆陌生动作堆叠。
    expect(buildMethod, contains('video_shader_quality_tier'),
        reason: '着色器详情顶部是画质档位 section');
    expect(buildMethod, contains('VideoShaderTierSelector('),
        reason: '五档单选器嵌入档位 section');
    // TODO-125：进阶 section 仅保留手动导入逃生口，删经典推荐着色器（RAVU/NNEDI3）入口。
    expect(buildMethod, contains('video_shader_section_advanced'));
    expect(buildMethod, contains('video_shader_section_installed'));
    expect(buildMethod, isNot(contains('video_shader_classic_recommended')),
        reason: 'TODO-125：删经典推荐着色器入口');
    expect(buildMethod, isNot(contains('_openRecommended')),
        reason: 'TODO-125：经典推荐着色器动作已删除');
    expect(buildMethod, isNot(contains('video_shader_download_anime4k')),
        reason: '诉求 2：不再单列「下载 Anime4K 推荐着色器」入口');
    // TODO-125 诉求 2：五档显卡要求常驻对照表（替换原单行 _tierHint）。
    expect(buildMethod, contains('VideoShaderTierComparison'),
        reason: 'TODO-125：五档显卡要求常驻对照表');
    expect(buildMethod, isNot(contains('_tierHint()')),
        reason: 'TODO-125：单行 _tierHint 已被五档对照表替换');
    expect(buildMethod, isNot(contains('Wrap(')),
        reason: '不能把下载/导入动作作为同级按钮堆在顶部');
  });
}
