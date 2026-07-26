import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

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
    // TODO-590 batch10：side-panel 域（_buildVideoSidePanelChild /
    // _buildVideoSidePanelOverlay / VideoTranslucentSidePanel 构造）已抽到
    // video_hibiki/side_panel.part.dart，改读合并语料才能命中这些 marker；
    // _showPlayerSettings / _buildVideoQuickSettingsSheet 仍在主壳（合并语料含主壳）。
    final String source = readVideoHibikiSource();
    final String showMethod = _member(
      source,
      'void _showPlayerSettings(',
    );
    // 阶段B：~60 个 initial*/on* 构造参数收敛为单个 VideoQuickSettingsHost 能力槽；
    // 页面接线断言从 _buildVideoQuickSettingsSheet 移到紧随其后的
    // _buildVideoQuickSettingsHost（回调/getter 都在 host 构造里）。
    final String buildMethod = _between(
      source,
      'Widget _buildVideoQuickSettingsSheet() {',
      'VideoQuickSettingsHost _buildVideoQuickSettingsHost() {',
    );
    final String hostMethod = _between(
      source,
      'VideoQuickSettingsHost _buildVideoQuickSettingsHost() {',
      'Future<void> _switchToSkiaAndRestart()',
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
    expect(buildMethod, contains('host: _buildVideoQuickSettingsHost()'),
        reason: '面板经类型化 host 能力槽拿页面回调（阶段B）');
    expect(buildMethod, contains('initialCategory: _settingsInitialCategory'));

    // 着色器/mpv 配置仍面板内嵌（不弹独立对话框）：页面回调经 host 接线，
    // 初值改由 schema/actions 层直接读 pref（initial* 参数已删）。
    expect(hostMethod, contains('onApplyShaders:'));
    expect(hostMethod, contains('onMpvConfigChanged:'));
    expect(hostMethod, contains('onLockWindowAspectRatioChanged:'));
    expect(hostMethod, contains('onAsbConfigChanged:'));
    // TODO-060：字幕调轴经 onSetDelay 绝对提交（滑条/±/输入框三处共享）；
    // 旧的增量 onSubtitleOffsetChanged 已删。权威延迟值经 getter 闭包进 host。
    expect(hostMethod, contains('onSetDelay:'));
    expect(hostMethod, contains('delayMs: () => _delayMs'));

    // 旧 bespoke 深色单列面板已移除（防回归）。
    expect(showMethod, isNot(contains('showModalBottomSheet')),
        reason: '播放设置不再走 bespoke bottom sheet');
    for (final String region in <String>[buildMethod, hostMethod]) {
      expect(region, isNot(contains('Colors.black87')));
      expect(region, isNot(contains('StatefulBuilder')));
      expect(region, isNot(contains('ChoiceChip')));
    }

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
    // 与阅读器同源的「不套外层滚动 + 宽窗撑满有界高度」范式（BUG-096）：外壳骨架
    // （PopScope + HibikiModalSheetFrame + scrollable:false + 几何判据）已抽到共享
    // HibikiMasterDetailSettingsSheet（TODO-583），由 master_detail_settings_sheet_test
    // 守它。这里只锁视频走共享外壳，且宽窗撑满有界高度的 height:constraints.maxHeight
    // 仍在视频自己的 wideBuilder 回调里。
    expect(source, contains('HibikiMasterDetailSettingsSheet('));
    expect(source, contains('height: constraints.maxHeight'));

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
    // TODO-1351（用户复诉）：顶栏 chip 恢复「图标 + 完整文字」，标签按固有宽度完整
    // 渲染（allowLabelOverflow，无 ellipsis）；TODO-640 的纯图标 + tooltip 方案废弃。
    expect(source, contains('allowLabelOverflow: true'),
        reason: 'top-bar category chips render full labels (TODO-1351)');
    expect(source, isNot(contains('iconOnly: true')),
        reason:
            'icon-only top-bar chips were rejected by the user (TODO-1351)');
    expect(source, isNot(contains('tooltip: cat.label')),
        reason: 'labels are inline now, not tooltip-only (TODO-1351)');
    expect(source, contains('_buildWideDetailTitle('),
        reason: 'the selected category title renders atop the detail pane');
    // BUG（用户复诉「弹幕 / 控制 分类被截在视口外、点不到」）：顶栏分类条放不下时必须
    // 换行堆叠（Wrap），不得回退横向 SingleChildScrollView 裁断——横滑会把末位分类推到
    // 视口外、无滚动条提示。守卫只扫 _buildTopCategoryBar 方法体，与
    // video_quick_settings_sheet_test 的同款守卫互为镜像。
    final String topBarSource = source.substring(
      source.indexOf('Widget _buildTopCategoryBar('),
      source.indexOf('Widget _buildWideDetailTitle('),
    );
    expect(topBarSource, contains('Wrap('),
        reason: 'the top category bar wraps so no category chip is clipped');
    expect(topBarSource, isNot(contains('scrollDirection: Axis.horizontal')),
        reason:
            'top category bar must wrap, not horizontally scroll (last chip '
            'was pushed off-screen and unclickable)');
    expect(source, contains('padding: widePrimaryPadding'));
    // 详情按选中 id KeyedSubtree，防 Element 复用副作用。
    expect(source, contains('KeyedSubtree('));
    expect(source, contains("_subPage ?? 'playback'"));
    // 分类齐全（chip 行 + 窄窗导航行共用 _categories）：审查 Finding 9 后由
    // VideoGroup 枚举驱动（id == 枚举名），每个分组必有 exhaustive switch 的
    // icon/label 映射分支——新增分组漏接面板会在编译期报错。
    expect(
        source, contains('for (final VideoGroup group in VideoGroup.values)'),
        reason: '_categories 必须由 VideoGroup.values 驱动，禁止手写平行列表');
    for (final String id in <String>[
      'playback',
      'audio',
      'shaders',
      'mpv',
      'subtitle',
      'danmaku',
      'controls',
    ]) {
      expect(source, contains('case VideoGroup.$id:'),
          reason: 'missing category mapping for $id');
    }

    // 阶段B：配置行不再手写在 sheet 里，sheet 只按分类投影 schema 渲染。
    expect(source, contains('buildVideoGroupDestination('),
        reason: '面板详情必须经 schema 投影（阶段B）');
    expect(source, contains('renderer.buildDetailContent('),
        reason: '面板详情必须经共享渲染器渲染（阶段B）');

    // 阶段B：行声明移入 settings_schema_video.dart / 内嵌 builder 移入
    // video_settings_actions.dart，守卫改锁新位置（保护不变：着色器/mpv 详情
    // 内嵌、锁窗口比/双击等行仍存在且双路写穿）。
    final String schemaSrc =
        File('lib/src/settings/settings_schema_video.dart').readAsStringSync();
    final String actionsSrc =
        File('lib/src/media/video/video_settings_actions.dart')
            .readAsStringSync();
    final String widgetsSrc =
        File('lib/src/settings/settings_schema_widgets.dart')
            .readAsStringSync();
    final String hostSrc =
        File('lib/src/media/video/video_quick_settings_host.dart')
            .readAsStringSync();
    expect(actionsSrc, contains('VideoShaderManagerView('),
        reason: '着色器详情内嵌 VideoShaderManagerView（builder 在 actions 层）');
    expect(schemaSrc, contains('dropdown: true'),
        reason: 'hwdec/aspect/channels 等长标签行声明 dropdown 渲染');
    expect(widgetsSrc, contains('AdaptiveSettingsPickerRow<T>('),
        reason: 'dropdown 声明经渲染层落成 AdaptiveSettingsPickerRow');
    expect(widgetsSrc, contains('AdaptiveSettingsStepperRow'),
        reason: 'stepper 行仍经共享渲染层渲染');
    expect(schemaSrc, contains('VideoMpvConfig.defaults'),
        reason: 'mpv 详情含「重置默认」action');
    expect(schemaSrc, contains('isDesktopPlatform'), reason: '锁窗口比行仍按桌面平台门控');
    expect(schemaSrc, contains('t.video_setting_mpv_aspect'));
    expect(schemaSrc, contains('pauseAtSubtitleEnd'));
    expect(hostSrc, contains('onLockWindowAspectRatioChanged'));
    expect(hostSrc, contains('onAsbConfigChanged'));
    expect(hostSrc, contains('onSetDelay'));
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
    // 阶段B：_buildShadersDetail 移出 sheet，改为 video_settings_actions.dart 的
    // buildVideoShaderManager（SettingsCustomItem builder）；守卫改锁新位置。
    final String actionsSource =
        File('lib/src/media/video/video_settings_actions.dart')
            .readAsStringSync();
    final String shaderDetail = _between(
      actionsSource,
      'Widget buildVideoShaderManager(',
      'Widget buildVideoMpvRawConfField(',
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
    // 锚点不带行尾 `{`：State 类挂 HibikiPagePlaceholders mixin 后声明折行。
    final String managerWidget = _between(
      shaderSource,
      'class VideoShaderManagerView extends StatefulWidget {',
      'class _VideoShaderManagerViewState extends State<VideoShaderManagerView>',
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
    final String source = readVideoHibikiSource();
    // TODO-314：字幕列表改 push-aside 后 overlay 版 _buildSubtitleListSidePanel 已删。
    // TODO-590 batch10：整个 side-panel 域（_buildVideoSidePanelOverlay /
    // _buildVideoSidePanelContent）已抽到 video_hibiki/side_panel.part.dart。该 part 在合并
    // 语料末尾，_buildVideoSidePanelContent 是它的末方法（下方断言要的
    // `kind != settings` / `HibikiAppUiScale` / `scale: _videoUiScale` 都落在 content 体里），
    // 其紧邻后继是 part 顶格 extension 闭合 `\n}`；overlay→content 之间无顶格 `}`，故用
    // `\n}` 作终点恰好涵盖 overlay+content 两个方法（旧的 _handlePlaybackDrop 终点已失效——
    // 它在主壳前段，排在搬出后的 overlay 之前）。
    final String panelMethod = _between(
      source,
      'Widget _buildVideoSidePanelOverlay(VideoPlayerController controller) {',
      '\n}',
    );
    final String visibilityMethod = _between(
      source,
      'void _markControlsVisible(bool visible) {',
      '/// 桌面鼠标移出视频区',
    );
    final String pokeMethod = _between(
      source,
      'void _pokeControlsVisible() {',
      'void _clearRailHover()',
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
    expect(pokeMethod,
        contains('device: _VideoHibikiPageState._syntheticHoverDevice'));
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
    expect(
        syntheticHoverMethod,
        contains(
            'event.device == _VideoHibikiPageState._syntheticHoverDevice'));
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
