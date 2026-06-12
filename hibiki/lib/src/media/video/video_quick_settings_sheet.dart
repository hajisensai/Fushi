import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/src/media/video/video_shader_tier.dart';
import 'package:hibiki/src/pages/implementations/video_shader_dialog.dart';
import 'package:hibiki/utils.dart';

/// 视频播放设置面板：与阅读器 `ReaderQuickSettingsSheet` 同款 master-detail
/// （宽窗左父菜单固定 + 右详情独立滚动；窄窗降级单列 push）。所有值都不是 schema
/// 项（每项都要回调进 `VideoHibikiPage` 即时调 controller / 持久化 / 实时预览），
/// 故全部用 bespoke 的 `AdaptiveSettings*` 行，不走 settings schema。
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
    this.uiScale = 1.0,
    this.initialMpvShaderDir = '',
    this.onMpvShaderDirChanged,
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

  /// Actual app UI scale. Video routes neutralize [HibikiAppUiScale] so the
  /// inherited scale inside the sheet can be 1.0 even when the app setting is
  /// larger or smaller.
  final double uiScale;

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
            final EdgeInsets bodyPadding = EdgeInsets.fromLTRB(
              tokens.spacing.page + tokens.spacing.gap / 2,
              tokens.spacing.gap / 2,
              tokens.spacing.page + tokens.spacing.gap / 2,
              tokens.spacing.card + tokens.spacing.gap + viewInsetsBottom,
            );
            if (_isWide) {
              final String selectedId = _subPage ?? 'playback';
              final Color dividerColor = isCupertinoPlatform(context)
                  ? CupertinoColors.separator.resolveFrom(context)
                  : tokens.surfaces.outline;
              final double wideHorizontalInset =
                  tokens.spacing.page + tokens.spacing.gap / 2;
              final EdgeInsets wideSupportingPadding = EdgeInsets.fromLTRB(
                wideHorizontalInset,
                tokens.spacing.gap / 2,
                wideHorizontalInset,
                tokens.spacing.card + tokens.spacing.gap + viewInsetsBottom,
              );
              final EdgeInsets widePrimaryPadding = EdgeInsets.fromLTRB(
                wideHorizontalInset,
                tokens.spacing.gap / 2,
                wideHorizontalInset,
                tokens.spacing.card + tokens.spacing.gap + viewInsetsBottom,
              );
              return SizedBox(
                height: constraints.maxHeight,
                child: MaterialSupportingPaneLayout(
                  minSplitWidth: kHibikiSettingsWideThreshold,
                  supportingWidth: kHibikiSettingsSupportingPaneWidth,
                  supportingSide: SupportingPaneSide.start,
                  dividerColor: dividerColor,
                  supporting: SingleChildScrollView(
                    padding: wideSupportingPadding,
                    child: _buildWidePane(theme, selectedId),
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

  /// 左父菜单的分类项（id 与 [_subPageContent] 的 case 对齐）。
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
    ];
  }

  /// 宽窗 master-detail 左 pane：标题 + 分类列表（单选高亮）。
  Widget _buildWidePane(ThemeData theme, String selectedId) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SettingsSectionHeader(
          t.video_settings_title,
          padding: EdgeInsets.only(bottom: tokens.spacing.gap),
        ),
        for (final ({String id, IconData icon, String label}) cat
            in _categories())
          HibikiListItem(
            selected: cat.id == selectedId,
            selectedShape: HibikiListItemSelectedShape.pill,
            leading: Icon(cat.icon),
            title: Text(cat.label),
            onTap: () => setState(() => _subPage = cat.id),
          ),
      ],
    );
  }

  /// 窄窗主页：标题 + 分类导航行（push 子页）。
  Widget _buildMainPage(ThemeData theme) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SettingsSectionHeader(
          t.video_settings_title,
          padding: EdgeInsets.only(bottom: tokens.spacing.gap),
        ),
        AdaptiveSettingsSection(
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
      default:
        return '';
    }
  }

  // ── 播放：音画延迟 + 倍速 ──────────────────────────────────────────────
  Widget _buildPlaybackDetail() {
    return AdaptiveSettingsSection(
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

  Widget _buildImmersiveModeRow() {
    return AdaptiveSettingsSegmentedRow<VideoImmersiveMode>(
      title: t.video_setting_immersive_mode,
      subtitle: t.video_setting_immersive_mode_hint,
      icon: Icons.lock_outline,
      controlBelow: true,
      segments: <ButtonSegment<VideoImmersiveMode>>[
        for (final VideoImmersiveMode mode in VideoImmersiveMode.values)
          ButtonSegment<VideoImmersiveMode>(
            value: mode,
            label: Text(_immersiveModeLabel(mode)),
            tooltip: _immersiveModeLabel(mode),
          ),
      ],
      selected: _immersiveMode,
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

    final Widget buttons = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
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
          child: SizedBox(
            width: 84,
            child: Text(
              label,
              textAlign: TextAlign.center,
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
      onChanged: (double v) => setState(() => _speed = _snapSpeed(v)),
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
        AdaptiveSettingsSection(
          title: t.video_setting_mpv_group_decode,
          children: <Widget>[
            AdaptiveSettingsPickerRow<String>(
              title: t.video_setting_mpv_hwdec,
              icon: Icons.memory_outlined,
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
        AdaptiveSettingsSection(
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
        AdaptiveSettingsSection(
          title: t.video_setting_mpv_group_geometry,
          children: <Widget>[
            AdaptiveSettingsPickerRow<int>(
              title: t.video_setting_mpv_rotate,
              icon: Icons.screen_rotation_outlined,
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
        AdaptiveSettingsSection(
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
        AdaptiveSettingsSection(
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
        AdaptiveSettingsSection(
          title: t.video_setting_mpv_group_playback,
          children: <Widget>[
            _mpvSwitch(t.video_setting_mpv_loop, c.loopFile,
                (bool v) => c.copyWith(loopFile: v),
                icon: Icons.repeat_outlined),
          ],
        ),
        SizedBox(height: gap),
        // 高级：原始 mpv.conf（多行逃生口，AdaptiveSettingsTextField 不支持多行故用原生）
        SettingsSectionHeader(t.video_setting_mpv_group_advanced),
        SizedBox(height: gap / 2),
        TextField(
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
        SizedBox(height: gap),
        // 重置：全部回 mpv 默认（含清空原始 conf 框）。
        AdaptiveSettingsSection(
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
        AdaptiveSettingsSection(
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
        AdaptiveSettingsSection(
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
                setState(() => _style = VideoSubtitleStyle.defaults);
                widget.onSubtitleStylePreview(VideoSubtitleStyle.defaults);
                widget.onSubtitleStyleCommit(VideoSubtitleStyle.defaults);
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
