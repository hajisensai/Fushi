import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/video_subtitle_style.dart';
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
    required this.onOpenShaders,
    required this.onOpenMpvConfig,
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

  /// 打开 mpv 着色器对话框（调用方应已关闭本面板）。
  final VoidCallback onOpenShaders;

  /// 打开 mpv 视频配置对话框（调用方应已关闭本面板）。
  final VoidCallback onOpenMpvConfig;

  @override
  State<VideoQuickSettingsSheet> createState() =>
      _VideoQuickSettingsSheetState();
}

class _VideoQuickSettingsSheetState extends State<VideoQuickSettingsSheet> {
  static const List<double> _speedPresets = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
  ];

  // 本地镜像：面板在独立的 dialog/bottom-sheet 路由里，父页面 setState 不会重建它，
  // 故乐观更新本地值（同旧 StatefulBuilder 的语义），再异步回调即时生效 + 落盘。
  late int _delayMs = widget.initialDelayMs;
  late double _speed = widget.initialSpeed;
  late bool _blur = widget.initialSubtitleBlur;
  late VideoSubtitleStyle _style = widget.initialSubtitleStyle;

  /// 窄窗 push 选中的子页 id；null = 主页。宽窗下恒有选中（默认 playback）。
  String? _subPage;

  /// 最近一次 LayoutBuilder 是否判定为宽窗（供 PopScope.canPop 读取）。
  bool _isWide = false;

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
            _isWide = constraints.maxWidth >= 640;
            final EdgeInsets bodyPadding = EdgeInsets.fromLTRB(
              tokens.spacing.page + tokens.spacing.gap / 2,
              tokens.spacing.gap / 2,
              tokens.spacing.page + tokens.spacing.gap / 2,
              tokens.spacing.card +
                  tokens.spacing.gap +
                  MediaQuery.of(context).viewInsets.bottom,
            );
            if (_isWide) {
              final String selectedId = _subPage ?? 'playback';
              final Color dividerColor = isCupertinoPlatform(context)
                  ? CupertinoColors.separator.resolveFrom(context)
                  : tokens.surfaces.outline;
              return SizedBox(
                height: constraints.maxHeight,
                child: Padding(
                  padding: bodyPadding,
                  child: MaterialSupportingPaneLayout(
                    minSplitWidth: 640,
                    supportingSide: SupportingPaneSide.start,
                    dividerColor: dividerColor,
                    supporting: SingleChildScrollView(
                      child: _buildWidePane(theme, selectedId),
                    ),
                    primary: KeyedSubtree(
                      key: ValueKey<String>(selectedId),
                      child: SingleChildScrollView(
                        child: _subPageContent(selectedId),
                      ),
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
        _buildDelayRow(),
        _buildSpeedRow(),
      ],
    );
  }

  Widget _buildDelayRow() {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String label = '${_delayMs >= 0 ? '+' : ''}$_delayMs ms';
    Future<void> bump(int delta) async {
      final int next = (_delayMs + delta).clamp(-600000, 600000);
      setState(() => _delayMs = next);
      await widget.onSetDelay(next);
    }

    return AdaptiveSettingsRow(
      title: t.video_setting_av_delay,
      subtitle: t.video_setting_av_delay_hint,
      icon: Icons.sync_outlined,
      controlBelow: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          HibikiIconButton(
            icon: Icons.keyboard_double_arrow_left,
            tooltip: '-1000ms',
            padding: EdgeInsets.all(tokens.spacing.gap / 2),
            onTap: () => bump(-1000),
          ),
          HibikiIconButton(
            icon: Icons.chevron_left,
            tooltip: '-50ms',
            padding: EdgeInsets.all(tokens.spacing.gap / 2),
            onTap: () => bump(-50),
          ),
          HibikiFocusable(
            onTap: _delayMs == 0
                ? null
                : () async {
                    setState(() => _delayMs = 0);
                    await widget.onSetDelay(0);
                  },
            child: SizedBox(
              width: 84,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: _delayMs == 0
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
            onTap: () => bump(50),
          ),
          HibikiIconButton(
            icon: Icons.keyboard_double_arrow_right,
            tooltip: '+1000ms',
            padding: EdgeInsets.all(tokens.spacing.gap / 2),
            onTap: () => bump(1000),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedRow() {
    return AdaptiveSettingsSegmentedRow<double>(
      title: t.video_setting_speed,
      icon: Icons.speed_outlined,
      controlBelow: true,
      segments: <ButtonSegment<double>>[
        for (final double s in _speedPresets)
          ButtonSegment<double>(
            value: s,
            label: Text('${s}x'),
            tooltip: '${s}x',
          ),
      ],
      selected: _nearestSpeedPreset(),
      onChanged: (double s) async {
        setState(() => _speed = s);
        await widget.onSetSpeed(s);
      },
    );
  }

  /// segmented 的 selected 必须等于某个档位值；当前倍速若落在档位间（极少见，
  /// 来自旧持久化），取最接近的档位高亮，避免无选中。
  double _nearestSpeedPreset() {
    double best = _speedPresets.first;
    double bestDiff = (best - _speed).abs();
    for (final double s in _speedPresets) {
      final double diff = (s - _speed).abs();
      if (diff < bestDiff) {
        best = s;
        bestDiff = diff;
      }
    }
    return best;
  }

  // ── 着色器 / mpv：导航到既有对话框 ─────────────────────────────────────
  Widget _buildShadersDetail() {
    return AdaptiveSettingsSection(
      children: <Widget>[
        AdaptiveSettingsNavigationRow(
          title: t.video_setting_shaders,
          subtitle: t.video_setting_shaders_hint,
          icon: Icons.auto_fix_high_outlined,
          showIcon: true,
          onTap: () {
            Navigator.of(context).pop();
            widget.onOpenShaders();
          },
        ),
      ],
    );
  }

  Widget _buildMpvDetail() {
    return AdaptiveSettingsSection(
      children: <Widget>[
        AdaptiveSettingsNavigationRow(
          title: t.video_setting_mpv_open,
          icon: Icons.tune,
          showIcon: true,
          onTap: () {
            Navigator.of(context).pop();
            widget.onOpenMpvConfig();
          },
        ),
      ],
    );
  }

  // ── 字幕：模糊 + 外观（字号/背景不透明度/位置 + 重置）─────────────────
  Widget _buildSubtitleDetail() {
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
