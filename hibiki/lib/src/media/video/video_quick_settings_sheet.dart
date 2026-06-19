import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/src/media/video/video_shader_tier.dart';
import 'package:hibiki/src/pages/implementations/video_shader_dialog.dart';
import 'package:hibiki/utils.dart';

const double _videoSettingsSupportingPaneReadableWidth = 312.0;
const double _videoSettingsPrimaryMinWidth = 320.0;

double _videoSettingsSupportingPaneWidth(double availableWidth) {
  final double maxSupportingWidth = math
      .max(
        kHibikiSettingsSupportingPaneWidth,
        availableWidth - _videoSettingsPrimaryMinWidth,
      )
      .toDouble();
  return math.min(
    _videoSettingsSupportingPaneReadableWidth,
    maxSupportingWidth,
  );
}

/// 视频播放设置面板：宽窗用「顶部横向分类 chip 行 + 下方详情」上下分栏
/// （TODO-427-③；详情独占整宽并独立滚动，分类条固定在顶部），窄窗降级单列 push。
/// 旧的左右 master-detail（窄左栏 + 右详情）因窄侧栏左右劈半把右详情挤窄、下拉抢宽裁
/// 标题而改成上下栏。所有值都不是 schema 项（每项都要回调进 `VideoHibikiPage` 即时调
/// controller / 持久化 / 实时预览），故全部用 bespoke 的 `AdaptiveSettings*` 行，不走
/// settings schema。
///
/// 配色用标准浅色 MD3（与阅读器一致），由 `HibikiModalSheetFrame` 提供 sheet 外壳，
/// 桌面经 `HibikiDialogFrame(maxWidth: 900)` 进入分栏、移动端走 bottom sheet。
class VideoQuickSettingsSheet extends StatefulWidget {
  const VideoQuickSettingsSheet({
    required this.initialDelayMs,
    required this.initialSpeed,
    required this.initialSubtitleBlur,
    required this.initialSubtitleStyle,
    required this.onSetDelay,
    required this.onPreviewSpeed,
    required this.onSetSpeed,
    required this.onToggleSubtitleBlur,
    required this.onSubtitleStylePreview,
    required this.onSubtitleStyleCommit,
    required this.initialAsbConfig,
    required this.onAsbConfigChanged,
    required this.initialShadersEnabled,
    required this.onApplyShaders,
    required this.onSelectShaderTier,
    required this.initialMpvConfig,
    required this.onMpvConfigChanged,
    required this.initialLockWindowAspectRatio,
    required this.onLockWindowAspectRatioChanged,
    required this.initialVideoFitMode,
    required this.onVideoFitModeChanged,
    required this.initialImmersiveMode,
    required this.onImmersiveModeChanged,
    this.initialControlLayout,
    this.onControlLayoutChanged,
    this.onEditControlsOnscreen,
    this.isTouchControls = false,
    this.uiScale = 1.0,
    this.initialMpvShaderDir = '',
    this.onMpvShaderDirChanged,
    this.initialDanmakuEnabled = true,
    this.initialDanmakuOnlineEnabled = true,
    this.initialDanmakuMaxActive = kDefaultVideoDanmakuMaxActive,
    this.onDanmakuEnabledChanged,
    this.onDanmakuOnlineEnabledChanged,
    this.onDanmakuMaxActiveChanged,
    super.key,
  });

  /// 当前音画延迟（ms），正=画面领先文本。
  final int initialDelayMs;

  /// 当前播放倍速。
  final double initialSpeed;

  /// 当前字幕模糊开关。
  final bool initialSubtitleBlur;

  /// 当前字幕外观样式。
  final VideoSubtitleStyle initialSubtitleStyle;

  /// 设音画延迟（绝对值），即时生效 + 持久化由调用方负责。
  final Future<void> Function(int delayMs) onSetDelay;

  /// 拖动倍速滑条时的实时预览（下发真实播放倍速，不落盘）。
  final Future<void> Function(double speed) onPreviewSpeed;

  /// 设播放倍速。
  final Future<void> Function(double speed) onSetSpeed;

  /// 切换字幕模糊。
  final Future<void> Function() onToggleSubtitleBlur;

  /// 拖动字幕外观滑条时的实时预览（更新页面背后的 overlay，不落盘）。
  final void Function(VideoSubtitleStyle style) onSubtitleStylePreview;

  /// 字幕外观定稿（拖动结束 / 重置）时落盘。
  final Future<void> Function(VideoSubtitleStyle style) onSubtitleStyleCommit;

  final VideoAsbplayerConfig initialAsbConfig;

  final Future<void> Function(VideoAsbplayerConfig config) onAsbConfigChanged;

  /// 初始启用的着色器文件名集合（内嵌着色器视图的初值）。
  final List<String> initialShadersEnabled;

  /// 着色器勾选变化时回调：持久化启用集 + 解析绝对路径 + 实时应用（调用方负责）。
  final Future<void> Function(List<String> enabledNames) onApplyShaders;

  /// 选画质档位回调：调用方原子持久化「mpv 内置缩放开关 [highQuality] + 启用集
  /// [enabledNames]」并一次性实时应用（避免分两个回调引入顺序耦合）。[tier] 仅供统计。
  final Future<void> Function(
    VideoShaderTier tier,
    bool highQuality,
    List<String> enabledNames,
  ) onSelectShaderTier;

  /// 用户上次手动指定的本机 mpv 配置/着色器目录（空=自动）。
  final String initialMpvShaderDir;

  /// 用户手动指定 mpv 目录后回调（持久化，调用方负责）。
  final Future<void> Function(String dir)? onMpvShaderDirChanged;

  /// 初始 mpv 配置（内嵌 mpv 配置详情的初值）。
  final VideoMpvConfig initialMpvConfig;

  /// mpv 配置任一项变化时回调：持久化 + 实时应用到播放器（即改即生效）。
  final Future<void> Function(VideoMpvConfig config) onMpvConfigChanged;

  /// 桌面端是否把原生窗口锁定为视频比例；移动端不显示。
  final bool initialLockWindowAspectRatio;

  /// 切换桌面窗口比例锁定。
  final Future<void> Function(bool value) onLockWindowAspectRatioChanged;

  /// 当前画面缩放/比例模式（窗口 + 全屏 Video fit；全平台显示）。
  final VideoFitMode initialVideoFitMode;

  /// 切画面缩放/比例模式（即时落盘 + 重建 Video，调用方负责）。
  final Future<void> Function(VideoFitMode mode) onVideoFitModeChanged;

  /// 侧边锁进入后的沉浸交互级别。
  final VideoImmersiveMode initialImmersiveMode;

  /// 切沉浸模式默认级别（即时落盘，下一次锁定和已锁定状态立即按 getter 生效）。
  final Future<void> Function(VideoImmersiveMode mode) onImmersiveModeChanged;

  /// 初始 9-槽位控制按钮布局（TODO-274/312 phase 2）。null = 当前 chrome 默认。
  final VideoControlLayout? initialControlLayout;

  /// 用户在控制条编辑器里改变某按钮槽位 / 显隐后回调：持久化 v2 布局 + 实时生效。
  final Future<void> Function(VideoControlLayout layout)?
      onControlLayoutChanged;

  /// 从设置页进入播放器画面内的拖拽编辑叠层（TODO-440）。
  final VoidCallback? onEditControlsOnscreen;

  /// 触屏控件（无右键菜单兜底）。为 true 时，控件布局编辑区禁止把「设置」按钮
  /// （玩家内进入设置/控件编辑器的唯一入口）拖入 hidden 移除，避免触屏用户把
  /// 自己锁死在玩家外（TODO-554）。桌面（false）保留可移除 + 右键恢复。
  final bool isTouchControls;

  /// Actual app UI scale. Video routes neutralize [HibikiAppUiScale] so the
  /// inherited scale inside the sheet can be 1.0 even when the app setting is
  /// larger or smaller.
  final double uiScale;

  final bool initialDanmakuEnabled;
  final bool initialDanmakuOnlineEnabled;
  final int initialDanmakuMaxActive;
  final Future<void> Function(bool value)? onDanmakuEnabledChanged;
  final Future<void> Function(bool value)? onDanmakuOnlineEnabledChanged;
  final Future<void> Function(int value)? onDanmakuMaxActiveChanged;

  @override
  State<VideoQuickSettingsSheet> createState() =>
      _VideoQuickSettingsSheetState();
}

class _VideoQuickSettingsSheetState extends State<VideoQuickSettingsSheet> {
  /// 倍速滑条范围/步长：与旧分段档位完全一致（0.5–2.0，0.1 步），持久化语义不变。
  static const double _speedMin = 0.5;
  static const double _speedMax = 2.0;

  /// (2.0 - 0.5) / 0.1 = 15 档，保证滑条只落在旧档位值上。
  static const int _speedDivisions = 15;

  // 本地镜像：面板在独立的 dialog/bottom-sheet 路由里，父页面 setState 不会重建它，
  // 故乐观更新本地值（同旧 StatefulBuilder 的语义），再异步回调即时生效 + 落盘。
  late int _delayMs = widget.initialDelayMs;
  late double _speed = widget.initialSpeed;
  late bool _blur = widget.initialSubtitleBlur;
  late bool _lockWindowAspectRatio = widget.initialLockWindowAspectRatio;
  late VideoFitMode _videoFitMode = widget.initialVideoFitMode;
  late VideoImmersiveMode _immersiveMode = widget.initialImmersiveMode;
  late VideoAsbplayerConfig _asbConfig = widget.initialAsbConfig;
  late VideoSubtitleStyle _style = widget.initialSubtitleStyle;
  late bool _danmakuEnabled = widget.initialDanmakuEnabled;
  late bool _danmakuOnlineEnabled = widget.initialDanmakuOnlineEnabled;
  late int _danmakuMaxActive =
      normalizeVideoDanmakuMaxActive(widget.initialDanmakuMaxActive);
  late VideoControlLayout _controlLayout =
      widget.initialControlLayout ?? VideoControlLayout.currentChrome;
  String? _controlMoveRejectionMessage;

  /// mpv 配置（内嵌详情即改即生效，本地权威 + 回调持久化/实时应用）。
  late VideoMpvConfig _mpvConfig = widget.initialMpvConfig;

  /// 当前启用的着色器文件名（内嵌着色器视图 onApply 回写，供切分类后重入回显）。
  late List<String> _shadersEnabled = widget.initialShadersEnabled;

  /// 用户手动指定的本机 mpv 目录（内嵌视图回写，供切分类后重入回显）。
  late String _mpvShaderDir = widget.initialMpvShaderDir;

  /// 原始 mpv.conf 文本框控制器（高级逃生口，多行；本地权威经 [_commitMpv] 落盘+应用）。
  late final TextEditingController _rawConfController =
      TextEditingController(text: widget.initialMpvConfig.rawConf);

  /// 字幕调轴数值输入框控制器（与滑条/± 按钮共享同一权威 [_delayMs]，经 [_commitDelay]
  /// 三处同步）。允许用户直接键入正负毫秒值。
  late final TextEditingController _delayController =
      TextEditingController(text: '${widget.initialDelayMs}');

  /// 字幕调轴滑条范围（±10 秒，覆盖绝大多数外挂字幕偏移；更大偏移仍可经输入框键入到
  /// ±600000，与 [VideoPlayerController] 的 clamp 一致）。
  static const int _subtitleSyncSliderRangeMs = 10000;
  static const int _subtitleSyncClampMs = 600000;

  /// 拖动字幕调轴滑条时的临时预览值（仅本地回显，松手才 [_commitDelay] 落盘+实时生效），
  /// 避免每个拖动 tick 都写 DB。null = 未在拖动。
  int? _delayDragMs;

  /// 窄窗 push 选中的子页 id；null = 主页。宽窗下恒有选中（默认 playback）。
  String? _subPage;

  /// 最近一次 LayoutBuilder 是否判定为宽窗（供 PopScope.canPop 读取）。
  /// 按窗口宽高确定性判定（>= 共享常量阈值），与书籍设置同条件。
  bool _isWide = false;

  @override
  void dispose() {
    _rawConfController.dispose();
    _delayController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(VideoQuickSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialControlLayout != widget.initialControlLayout) {
      _controlLayout =
          widget.initialControlLayout ?? VideoControlLayout.currentChrome;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return PopScope(
      // 宽窗 master-detail 选中态恒有值（默认 playback），返回键应直接关面板；
      // 窄窗 push 时保留「先回主页」语义。
      canPop: _subPage == null || _isWide,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop) {
          setState(() => _subPage = null);
        }
      },
      child: HibikiModalSheetFrame(
        maxHeightFactor: 0.80,
        // 与阅读器同源（BUG-096）：master-detail 绝不能套外层滚动，否则 supporting
        // pane 拿无界高度 → 左右一块滚 / 左不固定。frame 不滚，滚动策略下放到 body。
        scrollable: false,
        body: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 确定性几何判据（与书籍设置同一组常量）：宽且高都够才进宽窗
            // master-detail，否则窄窗 push。不测内容高度 → 同设备同尺寸下视频与
            // 书籍表现一致，且高度不足时直接 push 而非出滚动条。
            _isWide = constraints.maxWidth >= kHibikiSettingsWideThreshold &&
                constraints.maxHeight >= kHibikiSettingsWideMinHeight;
            final double viewInsetsBottom =
                MediaQuery.of(context).viewInsets.bottom;
            // TODO-344：四边按 MD3 spacing 放宽，消除「上下左右贴死」。水平用
            // page + gap（24），垂直顶部用 card（16）让内容离 sheet header / 分栏
            // divider 留出呼吸位，底部叠 card + gap + 键盘 inset。全部走 token，无裸值。
            final double horizontalInset =
                tokens.spacing.page + tokens.spacing.gap;
            final double topInset = tokens.spacing.card;
            final double bottomInset =
                tokens.spacing.card + tokens.spacing.gap + viewInsetsBottom;
            final EdgeInsets bodyPadding = EdgeInsets.fromLTRB(
              horizontalInset,
              topInset,
              horizontalInset,
              bottomInset,
            );
            if (_isWide) {
              final String selectedId = _subPage ?? 'playback';
              final Color dividerColor = isCupertinoPlatform(context)
                  ? CupertinoColors.separator.resolveFrom(context)
                  : tokens.surfaces.outline;
              final EdgeInsets wideSupportingPadding = EdgeInsets.fromLTRB(
                horizontalInset,
                topInset,
                horizontalInset,
                bottomInset,
              );
              final EdgeInsets widePrimaryPadding = EdgeInsets.fromLTRB(
                horizontalInset,
                topInset,
                horizontalInset,
                bottomInset,
              );
              return SizedBox(
                height: constraints.maxHeight,
                child: MaterialSupportingPaneLayout(
                  minSplitWidth: kHibikiSettingsWideThreshold,
                  supportingWidth: _videoSettingsSupportingPaneWidth(
                    constraints.maxWidth,
                  ),
                  supportingSide: SupportingPaneSide.start,
                  dividerColor: dividerColor,
                  supporting: SingleChildScrollView(
                    padding: wideSupportingPadding,
                    child: _buildWidePane(selectedId),
                  ),
                  primary: KeyedSubtree(
                    key: ValueKey<String>(selectedId),
                    child: SingleChildScrollView(
                      padding: widePrimaryPadding,
                      child: _subPageContent(selectedId),
                    ),
                  ),
                ),
              );
            }
            return SingleChildScrollView(
              padding: bodyPadding,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                child: _subPage != null
                    ? _buildSubPage(theme)
                    : _buildMainPage(theme),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 分类项（宽窗顶部 chip 行 + 窄窗导航行共用；id 与 [_subPageContent] 的 case 对齐）。
  List<({String id, IconData icon, String label})> _categories() {
    return <({String id, IconData icon, String label})>[
      (
        id: 'playback',
        icon: Icons.play_circle_outline,
        label: t.video_settings_cat_playback,
      ),
      (
        id: 'shaders',
        icon: Icons.auto_fix_high_outlined,
        label: t.video_settings_cat_shaders,
      ),
      (id: 'mpv', icon: Icons.tune, label: t.video_settings_cat_mpv),
      (
        id: 'subtitle',
        icon: Icons.subtitles_outlined,
        label: t.video_settings_cat_subtitle,
      ),
      (
        id: 'danmaku',
        icon: Icons.forum_outlined,
        label: t.video_settings_cat_danmaku,
      ),
      (
        id: 'controls',
        icon: Icons.dashboard_customize_outlined,
        label: t.video_settings_cat_controls,
      ),
    ];
  }

  Widget _buildWidePane(String selectedId) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return AdaptiveSettingsSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final ({String id, IconData icon, String label}) cat
              in _categories())
            HibikiListItem(
              selected: cat.id == selectedId,
              selectedShape: HibikiListItemSelectedShape.pill,
              leading: Icon(cat.icon),
              title: Text(cat.label),
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.gap + 2,
                vertical: tokens.spacing.gap,
              ),
              titleMaxLines: 3,
              onTap: () => setState(() => _subPage = cat.id),
            ),
        ],
      ),
    );
  }

  Widget _settingsSection({
    required List<Widget> children,
    String? title,
  }) {
    return AdaptiveSettingsSection(
      title: title,
      titlePlacement: SettingsSectionTitlePlacement.inside,
      children: children,
    );
  }

  Widget _textFieldSection({
    required String title,
    required Widget child,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return AdaptiveSettingsSection(
      title: title,
      titlePlacement: SettingsSectionTitlePlacement.inside,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.gap + tokens.spacing.gap / 2,
            tokens.spacing.gap,
            tokens.spacing.gap + tokens.spacing.gap / 2,
            tokens.spacing.gap + tokens.spacing.gap / 2,
          ),
          child: child,
        ),
      ],
    );
  }

  /// 窄窗主页：分类导航行（push 子页）。面板顶部 [VideoTranslucentSidePanel] 已有
  /// 「视频设置」统一标题，主页内部不再重复一个 [SettingsSectionHeader]（TODO-427）。
  Widget _buildMainPage(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _settingsSection(
          children: <Widget>[
            for (final ({String id, IconData icon, String label}) cat
                in _categories())
              AdaptiveSettingsNavigationRow(
                title: cat.label,
                icon: cat.icon,
                onTap: () => setState(() => _subPage = cat.id),
              ),
          ],
        ),
      ],
    );
  }

  /// 窄窗子页：返回页头 + 详情。
  Widget _buildSubPage(ThemeData theme) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String page = _subPage!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _VideoSettingsHeader(
          title: _subPageTitle(page),
          onBack: () => setState(() => _subPage = null),
        ),
        SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
        _subPageContent(page),
      ],
    );
  }

  /// 某分类的详情内容（不含返回页头）。窄窗 push 子页与宽窗右 pane 共用。
  Widget _subPageContent(String page) {
    switch (page) {
      case 'playback':
        return _buildPlaybackDetail();
      case 'shaders':
        return _buildShadersDetail();
      case 'mpv':
        return _buildMpvDetail();
      case 'subtitle':
        return _buildSubtitleDetail();
      case 'danmaku':
        return _buildDanmakuDetail();
      case 'controls':
        return _buildControlsDetail();
      default:
        return const SizedBox.shrink();
    }
  }

  String _subPageTitle(String page) {
    switch (page) {
      case 'playback':
        return t.video_settings_cat_playback;
      case 'shaders':
        return t.video_settings_cat_shaders;
      case 'mpv':
        return t.video_settings_cat_mpv;
      case 'subtitle':
        return t.video_settings_cat_subtitle;
      case 'danmaku':
        return t.video_settings_cat_danmaku;
      case 'controls':
        return t.video_settings_cat_controls;
      default:
        return '';
    }
  }

  // ── 播放：音画延迟 + 倍速 ──────────────────────────────────────────────
  Widget _buildPlaybackDetail() {
    return _settingsSection(
      children: <Widget>[
        _buildVideoFitModeRow(),
        if (isDesktopPlatform)
          AdaptiveSettingsSwitchRow(
            title: t.video_setting_lock_window_aspect,
            icon: Icons.aspect_ratio_outlined,
            value: _lockWindowAspectRatio,
            onChanged: (bool value) async {
              setState(() => _lockWindowAspectRatio = value);
              await widget.onLockWindowAspectRatioChanged(value);
            },
          ),
        _buildDelayRow(),
        _buildSpeedRow(),
        _buildLongPressSpeedRow(),
        _buildImmersiveModeRow(),
        _buildSeekSecondsRow(),
        _buildDoubleTapRow(),
        _buildSpeedStepRow(),
        _buildPauseAtSubtitleEndRow(),
      ],
    );
  }

  /// 画面缩放/比例模式（窗口 + 全屏 Video fit，TODO-152 子B）：保持比例占满(无黑边) /
  /// 保持比例完整(加黑边) / 拉伸填充。与 mpv 几何里的 aspectOverride 不同层（那个改 mpv
  /// 渲染管线），故独立一项、用专属文案。选中即落盘 + 重建 Video（调用方负责）。
  Widget _buildVideoFitModeRow() {
    return AdaptiveSettingsPickerRow<VideoFitMode>(
      title: t.video_setting_picture_fit,
      subtitle: t.video_setting_picture_fit_hint,
      icon: Icons.fit_screen_outlined,
      selected: _videoFitMode,
      controlBelow: true,
      materialWidth: double.infinity,
      options: <AdaptiveSettingsPickerOption<VideoFitMode>>[
        AdaptiveSettingsPickerOption<VideoFitMode>(
          value: VideoFitMode.cover,
          label: t.video_setting_picture_fit_cover,
        ),
        AdaptiveSettingsPickerOption<VideoFitMode>(
          value: VideoFitMode.contain,
          label: t.video_setting_picture_fit_contain,
        ),
        AdaptiveSettingsPickerOption<VideoFitMode>(
          value: VideoFitMode.fill,
          label: t.video_setting_picture_fit_fill,
        ),
      ],
      onChanged: (VideoFitMode mode) async {
        setState(() => _videoFitMode = mode);
        await widget.onVideoFitModeChanged(mode);
      },
    );
  }

  /// 沉浸锁定模式（解锁后仍放行哪些操作）：4 个模式的标签都是较长中文短语
  /// （全部功能 / 跳转 + 查词 / 仅查词 / 仅解锁），等宽不换行的 4 段
  /// [AdaptiveSettingsSegmentedRow]（SegmentedButton）在窄面板里挤不下、尾段被裁
  /// （沉浸四按钮显示不全 TODO-209）。改用与上方画面缩放行同款的
  /// [AdaptiveSettingsPickerRow]（下拉单选）：行内只显示当前选中标签（永不被裁），
  /// 展开后是每模式一行的竖排单选列表（4 项 < [kSettingsPickerInlineLimit]，
  /// 走 inline dropdown 分支，体验与画面缩放行一致）。
  Widget _buildImmersiveModeRow() {
    return AdaptiveSettingsPickerRow<VideoImmersiveMode>(
      title: t.video_setting_immersive_mode,
      subtitle: t.video_setting_immersive_mode_hint,
      icon: Icons.lock_outline,
      selected: _immersiveMode,
      options: <AdaptiveSettingsPickerOption<VideoImmersiveMode>>[
        for (final VideoImmersiveMode mode in VideoImmersiveMode.values)
          AdaptiveSettingsPickerOption<VideoImmersiveMode>(
            value: mode,
            label: _immersiveModeLabel(mode),
          ),
      ],
      onChanged: (VideoImmersiveMode mode) async {
        setState(() => _immersiveMode = mode);
        await widget.onImmersiveModeChanged(mode);
      },
    );
  }

  String _immersiveModeLabel(VideoImmersiveMode mode) {
    switch (mode) {
      case VideoImmersiveMode.full:
        return t.video_immersive_mode_full;
      case VideoImmersiveMode.seekAndLookup:
        return t.video_immersive_mode_seek_lookup;
      case VideoImmersiveMode.lookupOnly:
        return t.video_immersive_mode_lookup_only;
      case VideoImmersiveMode.unlockOnly:
        return t.video_immersive_mode_unlock_only;
    }
  }

  /// 字幕调轴权威提交：滑条 / ± 按钮 / 数值输入框三处共享。clamp 到 ±[_subtitleSyncClampMs]
  /// （与 [VideoPlayerController.setDelayMs] 一致），更新本地 [_delayMs]、可选回写输入框文本、
  /// 即时回调 [VideoQuickSettingsSheet.onSetDelay] 落盘+实时生效。
  Future<void> _commitDelay(int next, {bool syncField = true}) async {
    final int clamped = next.clamp(-_subtitleSyncClampMs, _subtitleSyncClampMs);
    setState(() => _delayMs = clamped);
    if (syncField && _delayController.text != '$clamped') {
      _delayController.text = '$clamped';
    }
    await widget.onSetDelay(clamped);
  }

  Widget _buildDelayRow() {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // 拖动中显示预览值，否则显示已落盘的权威值。
    final int shownMs = _delayDragMs ?? _delayMs;
    final String label = '${shownMs >= 0 ? '+' : ''}$shownMs ms';

    // 滑条只在 ±[_subtitleSyncSliderRangeMs] 内拖（细调常见偏移）；超出范围的当前值
    // 仍能通过输入框设置，滑条把手 clamp 到端点显示。
    final double sliderValue = shownMs
        .clamp(-_subtitleSyncSliderRangeMs, _subtitleSyncSliderRangeMs)
        .toDouble();

    final Widget buttons = Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: tokens.spacing.gap / 2,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        HibikiIconButton(
          icon: Icons.keyboard_double_arrow_left,
          tooltip: '-1000ms',
          padding: EdgeInsets.all(tokens.spacing.gap / 2),
          onTap: () => _commitDelay(_delayMs - 1000),
        ),
        HibikiIconButton(
          icon: Icons.chevron_left,
          tooltip: '-50ms',
          padding: EdgeInsets.all(tokens.spacing.gap / 2),
          onTap: () => _commitDelay(_delayMs - 50),
        ),
        HibikiFocusable(
          onTap: shownMs == 0 ? null : () => _commitDelay(0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 84, maxWidth: 140),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: shownMs == 0
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        HibikiIconButton(
          icon: Icons.chevron_right,
          tooltip: '+50ms',
          padding: EdgeInsets.all(tokens.spacing.gap / 2),
          onTap: () => _commitDelay(_delayMs + 50),
        ),
        HibikiIconButton(
          icon: Icons.keyboard_double_arrow_right,
          tooltip: '+1000ms',
          padding: EdgeInsets.all(tokens.spacing.gap / 2),
          onTap: () => _commitDelay(_delayMs + 1000),
        ),
      ],
    );

    return AdaptiveSettingsRow(
      title: t.video_setting_av_delay,
      subtitle: t.video_setting_av_delay_hint,
      icon: Icons.sync_outlined,
      controlBelow: true,
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 可拉滑条（细调 ±10s）：拖动只本地预览，松手才落盘+实时生效（避免每 tick 写 DB）。
          Slider(
            value: sliderValue,
            min: -_subtitleSyncSliderRangeMs.toDouble(),
            max: _subtitleSyncSliderRangeMs.toDouble(),
            divisions: _subtitleSyncSliderRangeMs ~/ 50, // 50ms 一档
            label: label,
            onChanged: (double v) => setState(() => _delayDragMs = v.round()),
            onChangeEnd: (double v) {
              setState(() => _delayDragMs = null);
              _commitDelay(v.round());
            },
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          buttons,
          SizedBox(height: tokens.spacing.gap / 2),
          // 数值输入框：可直接键入正负毫秒值（支持超出滑条范围的大偏移）。
          AdaptiveSettingsTextField(
            controller: _delayController,
            labelText: t.video_setting_subtitle_sync_input,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            textInputAction: TextInputAction.done,
            onSubmitted: (String raw) {
              final int? parsed = int.tryParse(raw.trim());
              if (parsed == null) {
                // 非法输入 → 回退到当前权威值，不改延迟。
                _delayController.text = '$_delayMs';
                return;
              }
              _commitDelay(parsed);
            },
          ),
        ],
      ),
    );
  }

  /// 倍速：MD3 全长滑条（与其它设置滑条同源 [AdaptiveSettingsSliderRow]，TODO-039，
  /// 取代旧的 16 段 segmented 条——窄面板下会横向滚动、与设计系统滑条不一致）。
  /// 范围/步长与旧档位一致（0.5–2.0，0.1 步）；拖动实时回显，松手提交
  /// [VideoQuickSettingsSheet.onSetSpeed]（键盘/手柄步进经 onChangeEnd 同样提交）。
  Widget _buildSpeedRow() {
    final double value = _snapSpeed(_speed);
    return AdaptiveSettingsSliderRow(
      title: t.video_setting_speed,
      icon: Icons.speed_outlined,
      min: _speedMin,
      max: _speedMax,
      divisions: _speedDivisions,
      value: value,
      label: '${value.toStringAsFixed(1)}x',
      onChanged: (double v) {
        final double snapped = _snapSpeed(v);
        setState(() => _speed = snapped);
        unawaited(widget.onPreviewSpeed(snapped));
      },
      onChangeEnd: (double v) async {
        final double snapped = _snapSpeed(v);
        setState(() => _speed = snapped);
        await widget.onSetSpeed(snapped);
      },
    );
  }

  /// 把滑条浮点值吸附到 0.1 档并夹进范围（消除二进制浮点尾差如 0.7000000000000001，
  /// 旧持久化的档位间值也归到最近档）。
  double _snapSpeed(double v) =>
      ((v * 10).roundToDouble() / 10).clamp(_speedMin, _speedMax).toDouble();

  Widget _buildLongPressSpeedRow() {
    final double value = _snapLongPressSpeed(_asbConfig.longPressSpeed);
    return AdaptiveSettingsSliderRow(
      title: t.video_setting_long_press_speed,
      subtitle: t.video_setting_long_press_speed_hint,
      icon: Icons.touch_app_outlined,
      min: 1.0,
      max: 4.0,
      divisions: 30,
      value: value,
      label: '${value.toStringAsFixed(1)}x',
      onChanged: (double v) {
        setState(
          () => _asbConfig = _asbConfig.copyWith(
            longPressSpeed: _snapLongPressSpeed(v),
          ),
        );
      },
      onChangeEnd: (double v) async {
        final VideoAsbplayerConfig next = _asbConfig.copyWith(
          longPressSpeed: _snapLongPressSpeed(v),
        );
        setState(() => _asbConfig = next);
        await widget.onAsbConfigChanged(next);
      },
    );
  }

  double _snapLongPressSpeed(double v) =>
      ((v * 10).roundToDouble() / 10).clamp(1.0, 4.0).toDouble();

  Widget _buildSeekSecondsRow() {
    return AdaptiveSettingsStepperRow(
      title: 'Seek seconds',
      icon: Icons.keyboard_double_arrow_right_outlined,
      value: _asbConfig.seekSeconds.toDouble(),
      step: 1,
      min: 1,
      max: 30,
      format: (double v) => '${v.round()}s',
      onChanged: (double v) => _commitAsb(
        _asbConfig.copyWith(seekSeconds: v.round()),
      ),
    );
  }

  /// 双击左/右区快进步长（TODO-173/BUG-231）。离散单选：关 / 3s / 5s / 10s / 下一句
  /// （字幕跳句）。值就是 [VideoAsbplayerConfig.doubleTapSeekSeconds]（0=关、3/5/10=
  /// 相对 seek 秒数、[VideoAsbplayerConfig.kDoubleTapSubtitle]=字幕跳句）。用与有声书
  /// `image_pause` 同款的 [AdaptiveSettingsSegmentedRow]（chips + 单焦点停 + 方向键步进，
  /// 焦点驱动友好）。onChanged 走 [_commitAsb] 落盘 + 即时回调页面。
  Widget _buildDoubleTapRow() {
    return AdaptiveSettingsSegmentedRow<int>(
      title: t.video_setting_double_tap,
      subtitle: t.video_setting_double_tap_hint,
      icon: Icons.touch_app_outlined,
      controlBelow: true,
      segments: <ButtonSegment<int>>[
        ButtonSegment<int>(
          value: 0,
          label: Text(t.video_setting_double_tap_off),
          tooltip: t.video_setting_double_tap_off,
        ),
        for (final int s in <int>[3, 5, 10])
          ButtonSegment<int>(
            value: s,
            label: Text('${s}s'),
            tooltip: '${s}s',
          ),
        ButtonSegment<int>(
          value: VideoAsbplayerConfig.kDoubleTapSubtitle,
          label: Text(t.video_setting_double_tap_subtitle),
          tooltip: t.video_setting_double_tap_subtitle,
        ),
      ],
      selected: _asbConfig.doubleTapSeekSeconds,
      onChanged: (int value) => _commitAsb(
        _asbConfig.copyWith(doubleTapSeekSeconds: value),
      ),
    );
  }

  Widget _buildSpeedStepRow() {
    return AdaptiveSettingsStepperRow(
      title: 'Speed step',
      icon: Icons.speed_outlined,
      value: _asbConfig.speedStep,
      step: 0.05,
      min: 0.05,
      max: 0.5,
      format: (double v) => v.toStringAsFixed(2),
      onChanged: (double v) => _commitAsb(
        _asbConfig.copyWith(speedStep: double.parse(v.toStringAsFixed(2))),
      ),
    );
  }

  Widget _buildPauseAtSubtitleEndRow() {
    return AdaptiveSettingsSwitchRow(
      title: t.playback_auto_pause,
      icon: Icons.pause_circle_outline,
      value: _asbConfig.pauseAtSubtitleEnd,
      onChanged: (bool value) => _commitAsb(
        _asbConfig.copyWith(pauseAtSubtitleEnd: value),
      ),
    );
  }

  void _commitAsb(VideoAsbplayerConfig next) {
    setState(() => _asbConfig = next);
    widget.onAsbConfigChanged(next);
  }

  // ── 着色器：内嵌管理视图（导入/发现/下载/勾选，不再弹独立对话框）────────
  Widget _buildShadersDetail() {
    return VideoShaderManagerView(
      // 切到别的分类再回来会重建本视图（宽窗 KeyedSubtree），用本地权威值回显。
      initialEnabled: _shadersEnabled,
      qualityEnhancementEnabled: _mpvConfig.highQuality,
      onQualityEnhancementChanged: (bool value) => _commitMpv(
        _mpvConfig.copyWith(highQuality: value),
      ),
      onApply: (List<String> names) async {
        setState(() => _shadersEnabled = names);
        await widget.onApplyShaders(names);
      },
      // 一键选档：原子回调由视频页同时落「内置缩放开关 + 启用集」并实时应用；本地同步
      // 镜像两套权威值，使切分类重入着色器详情时档位高亮 / 勾选状态正确回显。
      onSelectTier: (VideoShaderTier tier, bool highQuality,
          List<String> enabledNames) async {
        setState(() {
          _mpvConfig = _mpvConfig.copyWith(highQuality: highQuality);
          _shadersEnabled = enabledNames;
        });
        await widget.onSelectShaderTier(tier, highQuality, enabledNames);
      },
      initialMpvDir: _mpvShaderDir,
      titlePlacement: SettingsSectionTitlePlacement.inside,
      onMpvDirChanged: (String dir) async {
        setState(() => _mpvShaderDir = dir);
        await widget.onMpvShaderDirChanged?.call(dir);
      },
    );
  }

  /// mpv 配置改一项即落盘 + 实时应用（与倍速/字幕同款即改即生效，去掉保存/取消模态）。
  void _commitMpv(VideoMpvConfig next) {
    setState(() => _mpvConfig = next);
    widget.onMpvConfigChanged(next);
  }

  AdaptiveSettingsSwitchRow _mpvSwitch(
    String title,
    bool value,
    VideoMpvConfig Function(bool v) apply, {
    required IconData icon,
  }) {
    return AdaptiveSettingsSwitchRow(
      title: title,
      icon: icon,
      value: value,
      onChanged: (bool v) => _commitMpv(apply(v)),
    );
  }

  /// 色彩均衡 / 数值滑条（-min..max，divisions 全程整数）：拖动即 commit。
  AdaptiveSettingsSliderRow _mpvIntSlider(
    String title,
    IconData icon,
    int value,
    int min,
    int max,
    VideoMpvConfig Function(int v) apply,
  ) {
    return AdaptiveSettingsSliderRow(
      title: title,
      icon: icon,
      min: min.toDouble(),
      max: max.toDouble(),
      divisions: max - min,
      value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
      label: '$value',
      onChanged: (double v) => _commitMpv(apply(v.round())),
    );
  }

  // ── mpv：成体系配置内嵌详情（解码/画质/几何/色彩/音频/播放 + 原始 conf + 重置）──
  Widget _buildMpvDetail() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final VideoMpvConfig c = _mpvConfig;
    final double gap = tokens.spacing.gap;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 解码
        _settingsSection(
          title: t.video_setting_mpv_group_decode,
          children: <Widget>[
            AdaptiveSettingsPickerRow<String>(
              title: t.video_setting_mpv_hwdec,
              icon: Icons.memory_outlined,
              // 窄右详情 pane（~270-300px）里固定 220px 下拉会把 Expanded 标题挤到几乎 0
              // → 裁成「硬件…」（TODO-425）。controlBelow 让标题独占一行、下拉移到下方整行
              // 铺满（Material 端尊重，Cupertino 端仍走 inline）。
              controlBelow: true,
              selected: c.hwdec,
              options: <AdaptiveSettingsPickerOption<String>>[
                AdaptiveSettingsPickerOption<String>(
                    value: 'no', label: t.video_setting_mpv_hwdec_off),
                AdaptiveSettingsPickerOption<String>(
                    value: 'auto-safe', label: t.video_setting_mpv_hwdec_auto),
                AdaptiveSettingsPickerOption<String>(
                    value: 'auto-copy', label: t.video_setting_mpv_hwdec_copy),
              ],
              onChanged: (String v) => _commitMpv(c.copyWith(hwdec: v)),
            ),
          ],
        ),
        SizedBox(height: gap),
        // 画质
        _settingsSection(
          title: t.video_setting_mpv_group_quality,
          children: <Widget>[
            _mpvSwitch(t.video_setting_mpv_deband, c.deband,
                (bool v) => c.copyWith(deband: v),
                icon: Icons.gradient_outlined),
            _mpvSwitch(t.video_setting_mpv_dither, c.dither,
                (bool v) => c.copyWith(dither: v),
                icon: Icons.grain_outlined),
            _mpvSwitch(t.video_setting_mpv_interpolation, c.interpolation,
                (bool v) => c.copyWith(interpolation: v),
                icon: Icons.animation_outlined),
            _mpvSwitch(t.video_setting_mpv_deinterlace, c.deinterlace,
                (bool v) => c.copyWith(deinterlace: v),
                icon: Icons.view_stream_outlined),
            _mpvSwitch(t.video_setting_mpv_sigmoid, c.sigmoidUpscaling,
                (bool v) => c.copyWith(sigmoidUpscaling: v),
                icon: Icons.show_chart_outlined),
            _mpvSwitch(
                t.video_setting_mpv_correct_downscale,
                c.correctDownscaling,
                (bool v) => c.copyWith(correctDownscaling: v),
                icon: Icons.photo_size_select_small_outlined),
          ],
        ),
        SizedBox(height: gap),
        // 画面几何
        _settingsSection(
          title: t.video_setting_mpv_group_geometry,
          children: <Widget>[
            AdaptiveSettingsPickerRow<int>(
              title: t.video_setting_mpv_rotate,
              icon: Icons.screen_rotation_outlined,
              // 与 hwdec 同款：窄 pane 固定下拉抢宽度裁标题，统一 controlBelow 标题独占一行。
              controlBelow: true,
              selected: c.videoRotate,
              options: const <AdaptiveSettingsPickerOption<int>>[
                AdaptiveSettingsPickerOption<int>(value: 0, label: '0°'),
                AdaptiveSettingsPickerOption<int>(value: 90, label: '90°'),
                AdaptiveSettingsPickerOption<int>(value: 180, label: '180°'),
                AdaptiveSettingsPickerOption<int>(value: 270, label: '270°'),
              ],
              onChanged: (int v) => _commitMpv(c.copyWith(videoRotate: v)),
            ),
            AdaptiveSettingsPickerRow<String>(
              title: t.video_setting_mpv_aspect,
              icon: Icons.aspect_ratio_outlined,
              // 与 hwdec 同款：窄 pane 固定下拉抢宽度裁标题，统一 controlBelow 标题独占一行。
              controlBelow: true,
              selected: c.aspectOverride,
              options: <AdaptiveSettingsPickerOption<String>>[
                AdaptiveSettingsPickerOption<String>(
                    value: '-1', label: t.video_setting_mpv_aspect_auto),
                const AdaptiveSettingsPickerOption<String>(
                    value: '16:9', label: '16:9'),
                const AdaptiveSettingsPickerOption<String>(
                    value: '4:3', label: '4:3'),
                const AdaptiveSettingsPickerOption<String>(
                    value: '2.35:1', label: '2.35:1'),
                const AdaptiveSettingsPickerOption<String>(
                    value: '1:1', label: '1:1'),
              ],
              onChanged: (String v) =>
                  _commitMpv(c.copyWith(aspectOverride: v)),
            ),
            AdaptiveSettingsSliderRow(
              title: t.video_setting_mpv_zoom,
              icon: Icons.zoom_out_map_outlined,
              min: -2,
              max: 2,
              divisions: 40,
              value: c.videoZoom.clamp(-2.0, 2.0),
              label: c.videoZoom.toStringAsFixed(2),
              onChanged: (double v) => _commitMpv(c.copyWith(videoZoom: v)),
            ),
            AdaptiveSettingsSliderRow(
              title: t.video_setting_mpv_panscan,
              icon: Icons.crop_outlined,
              divisions: 20,
              value: c.panscan.clamp(0.0, 1.0),
              label: c.panscan.toStringAsFixed(2),
              onChanged: (double v) => _commitMpv(c.copyWith(panscan: v)),
            ),
          ],
        ),
        SizedBox(height: gap),
        // 色彩均衡
        _settingsSection(
          title: t.video_setting_mpv_group_color,
          children: <Widget>[
            _mpvIntSlider(
                t.video_setting_mpv_brightness,
                Icons.brightness_6_outlined,
                c.brightness,
                -100,
                100,
                (int v) => c.copyWith(brightness: v)),
            _mpvIntSlider(t.video_setting_mpv_contrast, Icons.contrast_outlined,
                c.contrast, -100, 100, (int v) => c.copyWith(contrast: v)),
            _mpvIntSlider(
                t.video_setting_mpv_saturation,
                Icons.invert_colors_outlined,
                c.saturation,
                -100,
                100,
                (int v) => c.copyWith(saturation: v)),
            _mpvIntSlider(t.video_setting_mpv_gamma, Icons.tonality_outlined,
                c.gamma, -100, 100, (int v) => c.copyWith(gamma: v)),
            _mpvIntSlider(t.video_setting_mpv_hue, Icons.colorize_outlined,
                c.hue, -100, 100, (int v) => c.copyWith(hue: v)),
          ],
        ),
        SizedBox(height: gap),
        // 音频
        _settingsSection(
          title: t.video_setting_mpv_group_audio,
          // TODO-060：删掉 mpv「音频延迟」入口——与「播放→字幕调轴」对用户而言重复混淆
          // （两者都是「延迟 (ms)」滑条，用户分不清）。字幕对不齐统一走字幕调轴
          // （_buildDelayRow，移字幕 cue）。audioDelayMs model 字段保留作旧配置 decode
          // 兼容，默认 0 不生效；不再暴露 UI 入口。
          children: <Widget>[
            _mpvSwitch(t.video_setting_mpv_pitch, c.audioPitchCorrection,
                (bool v) => c.copyWith(audioPitchCorrection: v),
                icon: Icons.graphic_eq_outlined),
            AdaptiveSettingsPickerRow<String>(
              title: t.video_setting_mpv_channels,
              icon: Icons.surround_sound_outlined,
              // 与 hwdec 同款：窄 pane 固定下拉抢宽度裁标题，统一 controlBelow 标题独占一行。
              controlBelow: true,
              selected: c.audioChannels,
              options: <AdaptiveSettingsPickerOption<String>>[
                AdaptiveSettingsPickerOption<String>(
                    value: 'auto-safe',
                    label: t.video_setting_mpv_channels_auto),
                AdaptiveSettingsPickerOption<String>(
                    value: 'stereo',
                    label: t.video_setting_mpv_channels_stereo),
                AdaptiveSettingsPickerOption<String>(
                    value: 'mono', label: t.video_setting_mpv_channels_mono),
              ],
              onChanged: (String v) => _commitMpv(c.copyWith(audioChannels: v)),
            ),
            _mpvSwitch(t.video_setting_mpv_normalize, c.normalizeDownmix,
                (bool v) => c.copyWith(normalizeDownmix: v),
                icon: Icons.compress_outlined),
          ],
        ),
        SizedBox(height: gap),
        // 播放
        _settingsSection(
          title: t.video_setting_mpv_group_playback,
          children: <Widget>[
            _mpvSwitch(t.video_setting_mpv_loop, c.loopFile,
                (bool v) => c.copyWith(loopFile: v),
                icon: Icons.repeat_outlined),
          ],
        ),
        SizedBox(height: gap),
        // 高级：原始 mpv.conf（多行逃生口，AdaptiveSettingsTextField 不支持多行故用原生）
        _textFieldSection(
          title: t.video_setting_mpv_group_advanced,
          child: TextField(
            controller: _rawConfController,
            minLines: 3,
            maxLines: 8,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              labelText: t.video_setting_mpv_raw,
              helperText: t.video_setting_mpv_raw_hint,
              helperMaxLines: 4,
              border: const OutlineInputBorder(),
            ),
            onChanged: (String v) => _commitMpv(c.copyWith(rawConf: v)),
          ),
        ),
        SizedBox(height: gap),
        // 重置：全部回 mpv 默认（含清空原始 conf 框）。
        _settingsSection(
          children: <Widget>[
            AdaptiveSettingsRow(
              title: t.video_setting_mpv_reset,
              icon: Icons.restart_alt_outlined,
              showIcon: true,
              onTap: () {
                _rawConfController.clear();
                _commitMpv(VideoMpvConfig.defaults);
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildControlsDetail() {
    return _buildControlDragEditor();
  }

  Widget _buildControlDragEditor() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return _settingsSection(
      children: <Widget>[
        Padding(
          padding: EdgeInsets.all(tokens.spacing.card),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildControlStagePreview(),
              if (_controlMoveRejectionMessage != null) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                Text(
                  _controlMoveRejectionMessage!,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: cs.error,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
              SizedBox(height: tokens.spacing.gap),
              _buildControlPalette(),
              SizedBox(height: tokens.spacing.gap),
              _buildHiddenSlotTray(),
            ],
          ),
        ),
        AdaptiveSettingsNavigationRow(
          title: t.video_control_reset_layout,
          subtitle: t.video_control_reset_layout_hint,
          icon: Icons.restart_alt_outlined,
          onTap: _resetControlLayout,
        ),
      ],
    );
  }

  Widget _buildControlStagePreview() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < 480;
        if (compact) {
          return DecoratedBox(
            key: const ValueKey<String>('video-control-editor-preview'),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: tokens.radii.controlRadius,
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.gap),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _buildCompactSlotGrid(<VideoControlSlot>[
                    VideoControlSlot.topLeft,
                    VideoControlSlot.topCenter,
                    VideoControlSlot.topRight,
                  ]),
                  SizedBox(height: tokens.spacing.gap),
                  _buildCompactSlotGrid(<VideoControlSlot>[
                    VideoControlSlot.screenLeft,
                    VideoControlSlot.screenRight,
                  ]),
                  SizedBox(height: tokens.spacing.gap),
                  _buildCompactSlotGrid(<VideoControlSlot>[
                    VideoControlSlot.bottomLeft,
                    VideoControlSlot.bottomCenter,
                    VideoControlSlot.bottomRight,
                  ]),
                ],
              ),
            ),
          );
        }

        final double stageWidth = constraints.maxWidth;
        final double stageHeight = math.min(
          420,
          math.max(260, stageWidth * 9 / 16),
        );
        return SizedBox(
          width: stageWidth,
          height: stageHeight,
          child: DecoratedBox(
            key: const ValueKey<String>('video-control-editor-preview'),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: tokens.radii.controlRadius,
              border: Border.all(color: cs.outlineVariant),
            ),
            child: ClipRRect(
              borderRadius: tokens.radii.controlRadius,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints preview) {
                  final double sideWidth =
                      math.min(224, math.max(128, preview.maxWidth * 0.24));
                  final double centerWidth =
                      math.min(236, math.max(128, preview.maxWidth * 0.22));
                  const double inset = 10;
                  return Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: <Color>[
                                cs.surfaceContainerHigh,
                                cs.surfaceContainerHighest,
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: inset,
                        left: inset,
                        width: sideWidth,
                        child: _buildSlotRegion(VideoControlSlot.topLeft),
                      ),
                      Positioned(
                        top: inset,
                        right: inset,
                        width: sideWidth,
                        child: _buildSlotRegion(VideoControlSlot.topRight),
                      ),
                      Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: inset),
                          child: SizedBox(
                            width: centerWidth,
                            child: _buildSlotRegion(
                              VideoControlSlot.topCenter,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: inset,
                        top: 0,
                        bottom: 0,
                        width: sideWidth,
                        child: Center(
                          child: _buildSlotRegion(VideoControlSlot.screenLeft),
                        ),
                      ),
                      Positioned(
                        right: inset,
                        top: 0,
                        bottom: 0,
                        width: sideWidth,
                        child: Center(
                          child: _buildSlotRegion(VideoControlSlot.screenRight),
                        ),
                      ),
                      Positioned(
                        left: inset,
                        bottom: inset,
                        width: sideWidth,
                        child: _buildSlotRegion(VideoControlSlot.bottomLeft),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: inset),
                          child: SizedBox(
                            width: centerWidth,
                            child: _buildSlotRegion(
                              VideoControlSlot.bottomCenter,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: inset,
                        bottom: inset,
                        width: sideWidth,
                        child: _buildSlotRegion(VideoControlSlot.bottomRight),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCompactSlotGrid(List<VideoControlSlot> slots) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
        final double gap = tokens.spacing.gap;
        final double itemWidth = constraints.maxWidth < 260
            ? constraints.maxWidth
            : (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final VideoControlSlot slot in slots)
              SizedBox(
                width: itemWidth,
                child: _buildSlotRegion(slot, growToContent: true),
              ),
          ],
        );
      },
    );
  }

  Widget _buildControlPalette() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(
              Icons.dashboard_customize_outlined,
              size: 18,
              color: cs.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t.video_control_palette_title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final VideoControlItem item
                in VideoControlItem.customizableItems)
              _buildDraggableControlChip(
                item,
                sourceSlot: null,
                sourceIndex: null,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildHiddenSlotTray() {
    return _buildSlotRegion(VideoControlSlot.hidden, tray: true);
  }

  Widget _buildSlotRegion(
    VideoControlSlot slot, {
    bool tray = false,
    bool growToContent = false,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<({VideoControlItem item, int sourceIndex})> entries =
        _slotChipEntries(slot);
    final bool removalSlot = slot == VideoControlSlot.hidden;
    return DragTarget<VideoControlDragData>(
      key: ValueKey<String>('video-control-edit-slot-${slot.storageValue}'),
      onWillAcceptWithDetails:
          (DragTargetDetails<VideoControlDragData> details) =>
              _handleControlDragWillAccept(details.data, slot),
      onAcceptWithDetails: (DragTargetDetails<VideoControlDragData> details) {
        _moveControlItem(
          details.data,
          slot,
          targetIndex: _controlLayout.itemsIn(slot).length,
        );
      },
      builder: (
        BuildContext context,
        List<VideoControlDragData?> candidate,
        List<dynamic> rejected,
      ) {
        final bool highlighted = candidate.isNotEmpty;
        final bool rejecting = rejected.isNotEmpty;
        final String? rejectionMessage =
            rejecting ? _controlMoveRejectionMessage : null;
        final Color borderColor = rejecting
            ? cs.error
            : highlighted
                ? cs.primary
                : cs.outlineVariant;
        final Widget chipArea = entries.isEmpty
            ? SizedBox(
                height: 32,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Icon(
                    removalSlot
                        ? Icons.remove_circle_outline
                        : Icons.add_circle_outline,
                    size: 18,
                    color: highlighted
                        ? cs.onPrimaryContainer
                        : cs.onSurfaceVariant,
                  ),
                ),
              )
            : Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final ({VideoControlItem item, int sourceIndex}) entry
                      in entries)
                    _buildPlacedControlChip(
                      entry.item,
                      sourceSlot: slot,
                      sourceIndex: entry.sourceIndex,
                    ),
                ],
              );
        final BoxConstraints containerConstraints = growToContent
            ? BoxConstraints(minHeight: tray ? 64 : 58)
            : BoxConstraints(
                minHeight: tray ? 64 : 58,
                maxHeight: tray ? 160 : 148,
              );
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: containerConstraints,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: highlighted
                ? cs.primaryContainer.withValues(alpha: 0.88)
                : cs.surface.withValues(alpha: tray ? 1 : 0.88),
            borderRadius: tokens.radii.controlRadius,
            border: Border.all(
              color: borderColor,
              width: highlighted || rejecting ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _controlSlotLabel(slot),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color:
                      highlighted ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (rejectionMessage != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  rejectionMessage,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              if (growToContent)
                chipArea
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: chipArea,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  List<({VideoControlItem item, int sourceIndex})> _slotChipEntries(
    VideoControlSlot slot,
  ) {
    final List<VideoControlItem> items = _controlLayout.itemsIn(slot);
    return <({VideoControlItem item, int sourceIndex})>[
      for (int index = 0; index < items.length; index++)
        if (items[index].isChipRenderable)
          (item: items[index], sourceIndex: index),
    ];
  }

  Widget _buildPlacedControlChip(
    VideoControlItem item, {
    required VideoControlSlot sourceSlot,
    required int sourceIndex,
  }) {
    return DragTarget<VideoControlDragData>(
      onWillAcceptWithDetails:
          (DragTargetDetails<VideoControlDragData> details) =>
              _handleControlDragWillAccept(details.data, sourceSlot),
      onAcceptWithDetails: (DragTargetDetails<VideoControlDragData> details) {
        _moveControlItem(
          details.data,
          sourceSlot,
          targetIndex: sourceIndex,
        );
      },
      builder: (
        BuildContext context,
        List<VideoControlDragData?> candidate,
        List<dynamic> rejected,
      ) {
        return _buildDraggableControlChip(
          item,
          sourceSlot: sourceSlot,
          sourceIndex: sourceIndex,
          highlighted: candidate.isNotEmpty,
        );
      },
    );
  }

  Widget _buildDraggableControlChip(
    VideoControlItem item, {
    required VideoControlSlot? sourceSlot,
    required int? sourceIndex,
    bool highlighted = false,
  }) {
    final Widget chip = _controlChipBody(
      item,
      sourceSlot: sourceSlot,
      sourceIndex: sourceIndex,
      dragging: false,
      highlighted: highlighted,
    );
    return Draggable<VideoControlDragData>(
      data: VideoControlDragData(
        item: item,
        sourceSlot: sourceSlot,
        sourceIndex: sourceIndex,
      ),
      hitTestBehavior: HitTestBehavior.opaque,
      feedback: Material(
        color: Colors.transparent,
        child: _controlChipBody(
          item,
          sourceSlot: sourceSlot,
          sourceIndex: sourceIndex,
          dragging: true,
          highlighted: false,
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: chip),
      onDraggableCanceled: (_, __) => _handleControlDragCanceled(item),
      child: chip,
    );
  }

  void _handleControlDragCanceled(VideoControlItem item) {
    final String? message = switch (item) {
      VideoControlItem.volume => t.video_control_reject_volume_bottom,
      _ => _controlMoveRejectionMessage,
    };
    if (message == null || _controlMoveRejectionMessage == message) return;
    setState(() => _controlMoveRejectionMessage = message);
  }

  Widget _controlChipBody(
    VideoControlItem item, {
    required VideoControlSlot? sourceSlot,
    required int? sourceIndex,
    required bool dragging,
    required bool highlighted,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String label = _controlItemLabel(item);
    final Color background =
        highlighted ? cs.primaryContainer : cs.secondaryContainer;
    final Color foreground =
        highlighted ? cs.onPrimaryContainer : cs.onSecondaryContainer;
    final String sourceSlotKey = sourceSlot?.storageValue ?? 'palette';
    final String sourceIndexKey = sourceIndex?.toString() ?? 'palette';
    final Widget body = SizedBox.square(
      dimension: 36,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: tokens.radii.controlRadius,
          border: Border.all(
            color: highlighted ? cs.primary : cs.outlineVariant,
            width: highlighted ? 1.5 : 1,
          ),
          boxShadow: dragging
              ? <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.24),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Icon(_controlItemIcon(item), size: 18, color: foreground),
      ),
    );
    return Tooltip(
      message: label,
      child: Semantics(
        key: dragging
            ? null
            : ValueKey<String>(
                'video-control-chip-${item.storageValue}-$sourceSlotKey-$sourceIndexKey',
              ),
        label: label,
        button: true,
        container: true,
        child: Listener(
          key: dragging
              ? null
              : ValueKey<String>(
                  'video-control-drag-chip-${item.storageValue}-$sourceSlotKey-$sourceIndexKey',
                ),
          behavior: HitTestBehavior.opaque,
          child: ExcludeSemantics(child: body),
        ),
      ),
    );
  }

  bool _canAcceptControlPayload(
    VideoControlDragData payload,
    VideoControlSlot target,
  ) {
    final VideoControlItem item = payload.item;
    if (!item.isChipRenderable) return false;
    if (!item.canMoveToSlot(
      target,
      isTouchControls: widget.isTouchControls,
    )) {
      return false;
    }
    if (payload.sourceSlot == target) return true;
    return !_controlLayout.itemsIn(target).contains(item);
  }

  bool _handleControlDragWillAccept(
    VideoControlDragData payload,
    VideoControlSlot target,
  ) {
    final bool accepted = _canAcceptControlPayload(payload, target);
    final String? message =
        accepted ? null : _controlRejectionMessage(payload.item, target);
    if (_controlMoveRejectionMessage != message) {
      setState(() => _controlMoveRejectionMessage = message);
    }
    return accepted;
  }

  String? _controlRejectionMessage(
    VideoControlItem item,
    VideoControlSlot target,
  ) {
    if (item == VideoControlItem.volume && !item.canMoveToSlot(target)) {
      return t.video_control_reject_volume_bottom;
    }
    if ((item.pinnedRequired ||
            (widget.isTouchControls && item.pinnedOnTouch)) &&
        target == VideoControlSlot.hidden) {
      return t.video_control_reject_required;
    }
    if (!item.canMoveToSlot(
      target,
      isTouchControls: widget.isTouchControls,
    )) {
      return t.video_control_reject_unavailable;
    }
    return null;
  }

  void _moveControlItem(
    VideoControlDragData payload,
    VideoControlSlot target, {
    int? targetIndex,
  }) {
    final VideoControlLayout next = _controlLayout.moveDraggedItem(
      payload,
      target,
      targetIndex: targetIndex,
    );
    if (next == _controlLayout) return;
    setState(() {
      _controlLayout = next;
      _controlMoveRejectionMessage = null;
    });
    final Future<void> Function(VideoControlLayout layout)? callback =
        widget.onControlLayoutChanged;
    if (callback != null) {
      unawaited(callback(next));
    }
  }

  void _resetControlLayout() {
    final VideoControlLayout next = VideoControlLayout.currentChrome;
    if (next == _controlLayout) return;
    setState(() {
      _controlLayout = next;
      _controlMoveRejectionMessage = null;
    });
    final Future<void> Function(VideoControlLayout layout)? callback =
        widget.onControlLayoutChanged;
    if (callback != null) {
      unawaited(callback(next));
    }
  }

  String _controlSlotLabel(VideoControlSlot slot) {
    switch (slot) {
      case VideoControlSlot.topLeft:
        return t.video_control_slot_top_left;
      case VideoControlSlot.topRight:
        return t.video_control_slot_top_right;
      case VideoControlSlot.bottomLeft:
        return t.video_control_slot_bottom_left;
      case VideoControlSlot.bottomCenter:
        return t.video_control_slot_bottom_center;
      case VideoControlSlot.bottomRight:
        return t.video_control_slot_bottom_right;
      case VideoControlSlot.screenLeft:
        return t.video_control_slot_screen_left;
      case VideoControlSlot.screenRight:
        return t.video_control_slot_screen_right;
      case VideoControlSlot.hidden:
        return t.video_control_slot_hidden;
      case VideoControlSlot.topCenter:
        return t.video_control_slot_top_center;
    }
  }

  String _controlItemLabel(VideoControlItem item) {
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) return _controlButtonLabel(legacy);
    switch (item) {
      case VideoControlItem.playPause:
        return t.video_control_play_pause;
      case VideoControlItem.back:
        return MaterialLocalizations.of(context).backButtonTooltip;
      case VideoControlItem.immersiveLock:
        return t.video_menu_lock;
      case VideoControlItem.seekBackward:
        return t.video_control_seek_backward;
      case VideoControlItem.seekForward:
        return t.video_control_seek_forward;
      case VideoControlItem.previousCue:
        return t.video_control_previous_cue;
      case VideoControlItem.nextCue:
        return t.video_control_next_cue;
      case VideoControlItem.fullscreen:
        return t.video_control_fullscreen;
      case VideoControlItem.screenshot:
        return t.video_control_screenshot;
      case VideoControlItem.clipExport:
        return t.video_clip_export;
      case VideoControlItem.subtitleTrack:
        return t.video_control_subtitle_track;
      case VideoControlItem.audioTrack:
        return t.video_control_audio_track;
      case VideoControlItem.previousEpisode:
        return t.video_prev_episode;
      case VideoControlItem.nextEpisode:
        return t.video_next_episode;
      case VideoControlItem.episodeList:
        return t.video_control_episode_list;
      case VideoControlItem.previousChapter:
        return t.shortcut_action_video_previous_chapter;
      case VideoControlItem.nextChapter:
        return t.shortcut_action_video_next_chapter;
      case VideoControlItem.chapterList:
        return t.video_chapters;
      case VideoControlItem.volume:
        return t.video_control_volume;
      case VideoControlItem.title:
        return t.video_control_title;
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.favoriteSentences:
      case VideoControlItem.settings:
        return item.storageValue;
    }
  }

  IconData _controlItemIcon(VideoControlItem item) {
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) return _controlButtonIcon(legacy);
    switch (item) {
      case VideoControlItem.playPause:
        return Icons.play_arrow_rounded;
      case VideoControlItem.back:
        return Icons.arrow_back;
      case VideoControlItem.immersiveLock:
        return Icons.lock_outline;
      case VideoControlItem.seekBackward:
        return Icons.fast_rewind;
      case VideoControlItem.seekForward:
        return Icons.fast_forward;
      case VideoControlItem.previousCue:
        return Icons.skip_previous;
      case VideoControlItem.nextCue:
        return Icons.skip_next;
      case VideoControlItem.fullscreen:
        return Icons.fullscreen;
      case VideoControlItem.screenshot:
        return Icons.photo_camera_outlined;
      case VideoControlItem.clipExport:
        return Icons.movie_creation_outlined;
      case VideoControlItem.subtitleTrack:
        return Icons.subtitles;
      case VideoControlItem.audioTrack:
        return Icons.audiotrack;
      case VideoControlItem.previousEpisode:
        return Icons.skip_previous_outlined;
      case VideoControlItem.nextEpisode:
        return Icons.skip_next_outlined;
      case VideoControlItem.episodeList:
        return Icons.playlist_play;
      case VideoControlItem.previousChapter:
        return Icons.first_page;
      case VideoControlItem.nextChapter:
        return Icons.last_page;
      case VideoControlItem.chapterList:
        return Icons.format_list_numbered;
      case VideoControlItem.volume:
        return Icons.volume_up_outlined;
      case VideoControlItem.title:
        return Icons.title;
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.favoriteSentences:
      case VideoControlItem.settings:
        return Icons.tune;
    }
  }

  String _controlButtonLabel(VideoControlButton button) {
    switch (button) {
      case VideoControlButton.speed:
        return t.video_control_speed;
      case VideoControlButton.subtitleList:
        return t.video_control_subtitle_list;
      case VideoControlButton.favoriteSentence:
        return t.video_control_favorite_sentence;
      case VideoControlButton.favoriteSentences:
        return t.video_control_favorite_sentences;
      case VideoControlButton.settings:
        return t.video_control_settings;
    }
  }

  IconData _controlButtonIcon(VideoControlButton button) {
    switch (button) {
      case VideoControlButton.speed:
        return Icons.speed_outlined;
      case VideoControlButton.subtitleList:
        return Icons.format_list_bulleted;
      case VideoControlButton.favoriteSentence:
        return Icons.star_border_rounded;
      case VideoControlButton.favoriteSentences:
        return Icons.collections_bookmark_outlined;
      case VideoControlButton.settings:
        return Icons.tune;
    }
  }

  // ── 字幕：模糊 + 外观（字号/背景不透明度/位置 + 重置）─────────────────
  Widget _buildSubtitleDetail() {
    final double uiScale = HibikiAppUiScale.normalize(widget.uiScale);
    final int resolvedFontWeight = _style.resolveFontWeight(uiScale);
    final double resolvedShadowThickness =
        _style.resolveShadowThickness(uiScale);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _settingsSection(
          children: <Widget>[
            AdaptiveSettingsSwitchRow(
              title: t.video_setting_subtitle_blur,
              subtitle: t.video_setting_subtitle_blur_hint,
              icon: Icons.blur_on_outlined,
              value: _blur,
              onChanged: (_) async {
                setState(() => _blur = !_blur);
                await widget.onToggleSubtitleBlur();
              },
            ),
          ],
        ),
        SizedBox(height: HibikiDesignTokens.of(context).spacing.gap),
        _settingsSection(
          title: t.video_setting_subtitle_appearance,
          children: <Widget>[
            AdaptiveSettingsSliderRow(
              title: t.video_setting_subtitle_font_size,
              icon: Icons.format_size_outlined,
              min: 12,
              max: 48,
              divisions: 36,
              value: _style.fontSize.clamp(12, 48),
              label: _style.fontSize.round().toString(),
              onChanged: (double v) =>
                  _previewStyle(_style.copyWith(fontSize: v)),
              onChangeEnd: (double v) =>
                  widget.onSubtitleStyleCommit(_style.copyWith(fontSize: v)),
            ),
            AdaptiveSettingsStepperRow(
              title: t.video_setting_subtitle_font_weight,
              icon: Icons.format_bold,
              value: resolvedFontWeight.toDouble(),
              step: 100,
              min: 100,
              max: 900,
              format: (double v) => v.round().toString(),
              onChanged: (double v) {
                final VideoSubtitleStyle next =
                    _style.copyWith(fontWeight: v.round());
                _previewStyle(next);
                widget.onSubtitleStyleCommit(next);
              },
            ),
            AdaptiveSettingsSliderRow(
              title: t.video_setting_subtitle_shadow,
              icon: Icons.format_color_text_outlined,
              min: 0,
              max: 12,
              divisions: 12,
              value: resolvedShadowThickness.clamp(0, 12),
              label: '${resolvedShadowThickness.round()}px',
              onChanged: (double v) =>
                  _previewStyle(_style.copyWith(shadowThickness: v)),
              onChangeEnd: (double v) => widget
                  .onSubtitleStyleCommit(_style.copyWith(shadowThickness: v)),
            ),
            AdaptiveSettingsSliderRow(
              title: t.video_setting_subtitle_bg_opacity,
              icon: Icons.opacity_outlined,
              divisions: 20,
              value: _style.backgroundOpacity.clamp(0, 1),
              onChanged: (double v) =>
                  _previewStyle(_style.copyWith(backgroundOpacity: v)),
              onChangeEnd: (double v) => widget
                  .onSubtitleStyleCommit(_style.copyWith(backgroundOpacity: v)),
            ),
            AdaptiveSettingsRow(
              title: t.video_setting_subtitle_no_background,
              subtitle: t.video_setting_subtitle_no_background_hint,
              icon: Icons.format_color_reset_outlined,
              showIcon: true,
              onTap: () => _applySubtitleStyle(
                _style.copyWith(backgroundOpacity: 0),
              ),
            ),
            AdaptiveSettingsSliderRow(
              title: t.video_setting_subtitle_position,
              icon: Icons.height_outlined,
              min: 0,
              max: 240,
              divisions: 24,
              value: _style.bottomPadding.clamp(0, 240),
              onChanged: (double v) =>
                  _previewStyle(_style.copyWith(bottomPadding: v)),
              onChangeEnd: (double v) => widget
                  .onSubtitleStyleCommit(_style.copyWith(bottomPadding: v)),
            ),
            AdaptiveSettingsRow(
              title: t.video_setting_subtitle_reset,
              icon: Icons.restart_alt_outlined,
              showIcon: true,
              onTap: () {
                _applySubtitleStyle(VideoSubtitleStyle.defaults);
              },
            ),
          ],
        ),
      ],
    );
  }

  /// 滑条拖动期：更新本地样式（重绘本面板滑条）+ 通知页面实时预览背后字幕。
  void _previewStyle(VideoSubtitleStyle next) {
    setState(() => _style = next);
    widget.onSubtitleStylePreview(next);
  }

  /// 离散动作（重置 / 无背景）也要同步本地镜像，否则 sheet 内滑条会滞后一帧或
  /// 一直显示旧值，直到父页面重建。
  void _applySubtitleStyle(VideoSubtitleStyle next) {
    setState(() => _style = next);
    widget.onSubtitleStylePreview(next);
    widget.onSubtitleStyleCommit(next);
  }

  Widget _buildDanmakuDetail() {
    return _settingsSection(
      children: <Widget>[
        AdaptiveSettingsSwitchRow(
          title: t.video_setting_danmaku_enabled,
          subtitle: t.video_setting_danmaku_enabled_hint,
          icon: Icons.forum_outlined,
          value: _danmakuEnabled,
          onChanged: (bool value) async {
            setState(() => _danmakuEnabled = value);
            await widget.onDanmakuEnabledChanged?.call(value);
          },
        ),
        AdaptiveSettingsSwitchRow(
          title: t.video_setting_danmaku_online,
          subtitle: t.video_setting_danmaku_online_hint,
          icon: Icons.cloud_sync_outlined,
          value: _danmakuOnlineEnabled,
          onChanged: (bool value) async {
            setState(() => _danmakuOnlineEnabled = value);
            await widget.onDanmakuOnlineEnabledChanged?.call(value);
          },
        ),
        AdaptiveSettingsStepperRow(
          title: t.video_setting_danmaku_max_active,
          subtitle: t.video_setting_danmaku_max_active_hint,
          icon: Icons.speed_outlined,
          value: _danmakuMaxActive.toDouble(),
          step: 10,
          min: 10,
          max: kMaxVideoDanmakuActive.toDouble(),
          format: (double v) => v.round().toString(),
          onChanged: (double value) async {
            final int next = normalizeVideoDanmakuMaxActive(value.round());
            setState(() => _danmakuMaxActive = next);
            await widget.onDanmakuMaxActiveChanged?.call(next);
          },
        ),
      ],
    );
  }
}

/// 窄窗子页返回页头（与阅读器面板同款）。
class _VideoSettingsHeader extends StatelessWidget {
  const _VideoSettingsHeader({required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final TextStyle? titleStyle = cupertino
        ? CupertinoTheme.of(context).textTheme.navTitleTextStyle
        : Theme.of(context).textTheme.titleMedium;
    final IconData icon =
        cupertino ? CupertinoIcons.chevron_back : Icons.arrow_back;

    return Row(
      children: <Widget>[
        if (cupertino)
          Semantics(
            button: true,
            label: t.back,
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              minSize: 36,
              onPressed: onBack,
              child: Icon(icon, size: 22),
            ),
          )
        else
          HibikiIconButton(
            icon: icon,
            tooltip: t.back,
            padding: EdgeInsets.all(tokens.spacing.gap / 2),
            onTap: onBack,
          ),
        SizedBox(width: tokens.spacing.gap / 2),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
      ],
    );
  }
}
