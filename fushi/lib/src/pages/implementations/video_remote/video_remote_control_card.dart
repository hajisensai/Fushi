import 'dart:async';
import 'dart:math' as math;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_remote_control_layout.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_models.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isEinkTheme, isGlassDesign;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiAppleSlider;
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show ShelfCoverFrame;
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';

/// 控制卡的两种形态。
enum VideoRemoteControlCardVariant {
  /// 竖屏底部浮动卡：进度 + 主控制组 + 纯图标次组（命中区 ≥48，放不下的收进
  /// 「⋯」）。
  floating,

  /// 横屏 / 平板左栏信息卡：封面缩略图 + 作品名 / 集数 / 电脑名 + 可拖动波浪
  /// 进度 + 主控制组 + 次组按钮网格 + 回到当前句。
  panel,
}

/// 控制按钮的最小命中区（底部浮动工具栏规则：≥48dp）。
const double kVideoRemoteMinTapTarget = 48;

/// 卡片圆角（MD3 extra-large 28，与歌词模式播放卡同档）。
const double _kCardRadius = 28;

/// 遥控器控制卡（纯展示）。按钮排布来自 [layout]（用户可自定义：主组 / 次组 /
/// 移出），按下回调 [onControl]；进度读 [clock]，[onSeek] 非空时进度条可拖。
class VideoRemoteControlCard extends StatelessWidget {
  const VideoRemoteControlCard({
    super.key,
    required this.layout,
    required this.nowPlaying,
    required this.onControl,
    this.variant = VideoRemoteControlCardVariant.floating,
    this.clock,
    this.onSeek,
    this.following = true,
    this.isEnabled,
  });

  final VideoRemoteControlLayout layout;
  final VideoRemoteNowPlaying nowPlaying;

  /// 按下某个控制按钮（含「回到当前句」）。
  final ValueChanged<VideoRemoteControlItem> onControl;

  final VideoRemoteControlCardVariant variant;

  /// 播放进度读口；null = 不显示进度条（还没有视频）。
  final FushiPlaybackClock? clock;

  /// 拖动进度条松手跳转；null = 进度条只显示。
  final ValueChanged<Duration>? onSeek;

  /// 字幕列表是否在跟随当前句（横屏卡里「回到当前句」只在 false 时浮出）。
  final bool following;

  /// 某按钮当前是否可用；null = 全部可用。
  final bool Function(VideoRemoteControlItem item)? isEnabled;

  bool _enabled(VideoRemoteControlItem item) => isEnabled?.call(item) ?? true;

  VoidCallback? _handler(VideoRemoteControlItem item) =>
      _enabled(item) ? () => onControl(item) : null;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: fushiFloatingPillDecoration(
        context,
        color: fushiFloatingToolbarPalette(context).container,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(_kCardRadius)),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(_kCardRadius)),
        ),
        child: switch (variant) {
          VideoRemoteControlCardVariant.floating => _buildFloating(context),
          VideoRemoteControlCardVariant.panel => _buildPanel(context),
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 竖屏浮动卡
  // -------------------------------------------------------------------------

  Widget _buildFloating(BuildContext context) {
    final FushiPlaybackClock? clock = this.clock;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth;
          final ({
            List<VideoRemoteControlItem> primary,
            List<VideoRemoteControlItem> secondary,
          })
          rows = _splitRows(width, playSize: 64);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (clock != null)
                VideoRemoteSeekBar(
                  key: const ValueKey<String>('video-remote-seek-bar'),
                  clock: clock,
                  isPlaying: nowPlaying.isPlaying,
                  onSeek: onSeek,
                  strokeWidth: 4,
                  barHeight: 28,
                ),
              const SizedBox(height: 6),
              Center(child: _primaryGroup(context, rows.primary, playSize: 64)),
              if (rows.secondary.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                _SecondaryIconRow(
                  items: rows.secondary,
                  width: width,
                  nowPlaying: nowPlaying,
                  enabled: _enabled,
                  onControl: onControl,
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 主组放不下时（用户把太多按钮拖进主组），把放不下的非播放键挪到次组行，
  /// 保证每颗按钮都是真实命中区，不整体缩放。
  ({
    List<VideoRemoteControlItem> primary,
    List<VideoRemoteControlItem> secondary,
  })
  _splitRows(double width, {required double playSize}) {
    final List<VideoRemoteControlItem> primary = layout.primaryItems;
    const double side = 56;
    const double gap = 8;
    final List<VideoRemoteControlItem> shown = <VideoRemoteControlItem>[];
    final List<VideoRemoteControlItem> moved = <VideoRemoteControlItem>[];
    double used = 0;
    for (final VideoRemoteControlItem item in primary) {
      final double need =
          (item == VideoRemoteControlItem.playPause ? playSize : side) +
          (shown.isEmpty ? 0 : gap);
      if (item == VideoRemoteControlItem.playPause || used + need <= width) {
        shown.add(item);
        used += need;
      } else {
        moved.add(item);
      }
    }
    return (
      primary: shown,
      secondary: <VideoRemoteControlItem>[...moved, ...layout.secondaryItems],
    );
  }

  /// 主控制组：播放键是最强调的填充形变键，其余（上一句 / 下一句与用户拖进
  /// 这一行的任意按钮）统一 M size tonal 容器，同尺寸同形状成一组。
  Widget _primaryGroup(
    BuildContext context,
    List<VideoRemoteControlItem> items, {
    required double playSize,
  }) {
    return FushiButtonGroup(
      key: const ValueKey<String>('video-remote-primary-group'),
      children: <Widget>[
        for (final VideoRemoteControlItem item in items)
          if (item == VideoRemoteControlItem.playPause)
            FushiExpressivePlayButton(
              key: const ValueKey<String>('video-remote-control-playPause'),
              isPlaying: nowPlaying.isPlaying,
              size: playSize,
              onPressed: _handler(item),
            )
          else
            FushiIconButtonControl.filledTonal(
              key: ValueKey<String>(
                'video-remote-control-${item.storageValue}',
              ),
              size: ButtonSizeVariant.medium,
              tooltip: _tooltip(item),
              isSelected: _toggleState(item),
              style: videoRemotePrimaryToggleStyle(
                context,
                isToggle: _toggleState(item) != null,
              ),
              onPressed: _handler(item),
              icon: FushiIcon(
                videoRemoteControlIcon(
                  item,
                  active: videoRemoteControlActive(item, nowPlaying),
                ),
              ),
            ),
      ],
    );
  }

  bool? _toggleState(VideoRemoteControlItem item) => switch (item) {
    VideoRemoteControlItem.favorite => nowPlaying.currentFavorited,
    VideoRemoteControlItem.subtitleVisibility => nowPlaying.subtitlesVisible,
    _ => null,
  };

  String _tooltip(VideoRemoteControlItem item) {
    final String label = videoRemoteControlLabel(
      item,
      active: videoRemoteControlActive(item, nowPlaying),
    );
    if (item == VideoRemoteControlItem.speed) {
      return '$label ${formatVideoRemoteSpeed(nowPlaying.speed)}';
    }
    final int? volume = nowPlaying.volume;
    if (item == VideoRemoteControlItem.volume && volume != null) {
      return '$label $volume';
    }
    return label;
  }

  // -------------------------------------------------------------------------
  // 横屏左栏
  // -------------------------------------------------------------------------

  Widget _buildPanel(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final FushiTypography type = context.fushiType;
    final FushiPlaybackClock? clock = this.clock;
    final String episode = (nowPlaying.episodeLabel ?? '').trim();
    final String host = (nowPlaying.hostName ?? '').trim();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double inner = math.max(0, constraints.maxWidth - 40);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _CoverThumb(cover: nowPlaying.cover, size: 72),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (episode.isNotEmpty)
                          Text(
                            episode,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: type.labelLargeEmphasized.copyWith(
                              color: cs.primary,
                            ),
                          ),
                        Text(
                          nowPlaying.title.isEmpty
                              ? t.video_remote_title
                              : nowPlaying.title,
                          key: const ValueKey<String>(
                            'video-remote-panel-title',
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: type.titleLargeEmphasized.copyWith(
                            color: cs.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (host.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _HostChip(name: host),
                ),
              ],
              if (clock != null) ...<Widget>[
                const SizedBox(height: 16),
                VideoRemoteSeekBar(
                  key: const ValueKey<String>('video-remote-seek-bar'),
                  clock: clock,
                  isPlaying: nowPlaying.isPlaying,
                  onSeek: onSeek,
                  strokeWidth: 6,
                  barHeight: 40,
                ),
              ],
              const SizedBox(height: 12),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: _primaryGroup(
                  context,
                  layout.primaryItems,
                  playSize: 80,
                ),
              ),
              if (layout.secondaryItems.isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                _SecondaryGrid(
                  items: layout.secondaryItems,
                  width: inner,
                  nowPlaying: nowPlaying,
                  enabled: _enabled,
                  onControl: onControl,
                ),
              ],
              FushiChromeReveal(
                visible: !following,
                from: AxisDirection.down,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FushiPressScale(
                    child: FushiFilledButton.tonalIcon(
                      key: const ValueKey<String>(
                        'video-remote-panel-return-current',
                      ),
                      onPressed: () =>
                          onControl(VideoRemoteControlItem.followCurrent),
                      icon: const FushiIcon(FushiIcons.myLocation),
                      label: Text(t.video_remote_current),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 主控制组里开关类按钮（收藏 / 字幕显隐）的 MD3 着色。
///
/// M3E tonal 图标按钮的 toggle 未选态退成 surfaceContainer——正好是遥控卡
/// 自身的底色（[fushiFloatingToolbarPalette] 的 container），于是开关键放进
/// 主控制行、关着时只剩一个裸图标，和旁边上一句 / 下一句的 tonal 容器不成组
/// （BUG-3495）。这里让它无论开关都铺与前后句同一个 secondaryContainer：开 /
/// 关由图标（实心 / 空心）与 M3E 选中形状（圆 → 方圆角）区分，选中语义仍走
/// `isSelected`。
///
/// 非开关按钮、Apple 设计系统（tonal = 中性 bordered 灰底圆钮，未选与前后句
/// 本就同色）、墨水屏（不套 Expressive 配色）返回 null，沿用组件默认。
@visibleForTesting
ButtonStyle? videoRemotePrimaryToggleStyle(
  BuildContext context, {
  required bool isToggle,
}) {
  if (!isToggle || isGlassDesign(context) || isEinkTheme(context)) return null;
  final ColorScheme cs = Theme.of(context).colorScheme;
  Color foreground(Set<WidgetState> states) =>
      states.contains(WidgetState.disabled)
      ? cs.onSurface.withValues(alpha: 0.38)
      : cs.onSecondaryContainer;
  return ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith<Color?>(
      (Set<WidgetState> states) => states.contains(WidgetState.disabled)
          ? cs.onSurface.withValues(alpha: 0.12)
          : cs.secondaryContainer,
    ),
    foregroundColor: WidgetStateProperty.resolveWith<Color?>(foreground),
    overlayColor: WidgetStateProperty.resolveWith<Color?>((
      Set<WidgetState> states,
    ) {
      final Color fg = foreground(states);
      if (states.contains(WidgetState.pressed) ||
          states.contains(WidgetState.focused)) {
        return fg.withValues(alpha: 0.1);
      }
      if (states.contains(WidgetState.hovered)) {
        return fg.withValues(alpha: 0.08);
      }
      return null;
    }),
  );
}

/// 竖屏次组：一排纯图标按钮（每颗 48 命中区，不画分隔线），放不下的按钮收进
/// 末尾「⋯」（宽度够就全部平铺）。
class _SecondaryIconRow extends StatelessWidget {
  const _SecondaryIconRow({
    required this.items,
    required this.width,
    required this.nowPlaying,
    required this.enabled,
    required this.onControl,
  });

  final List<VideoRemoteControlItem> items;
  final double width;
  final VideoRemoteNowPlaying nowPlaying;
  final bool Function(VideoRemoteControlItem item) enabled;
  final ValueChanged<VideoRemoteControlItem> onControl;

  static const double _slot = kVideoRemoteMinTapTarget + 4;

  @override
  Widget build(BuildContext context) {
    final int capacity = math.max(1, (width / _slot).floor());
    final bool overflow = items.length > capacity;
    final int shownCount = overflow ? capacity - 1 : items.length;
    final List<VideoRemoteControlItem> shown = items.take(shownCount).toList();
    final List<VideoRemoteControlItem> rest = items.skip(shownCount).toList();
    final Color foreground = fushiFloatingToolbarPalette(context).foreground;
    return Row(
      key: const ValueKey<String>('video-remote-secondary-row'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (final VideoRemoteControlItem item in shown)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: _IconControl(
              item: item,
              nowPlaying: nowPlaying,
              onPressed: enabled(item) ? () => onControl(item) : null,
            ),
          ),
        if (rest.isNotEmpty)
          SizedBox.square(
            dimension: kVideoRemoteMinTapTarget,
            child: FushiToolbarOverflowButton(
              foreground: foreground,
              items: <FushiToolbarItem>[
                for (final VideoRemoteControlItem item in rest)
                  FushiToolbarItem(
                    key: ValueKey<String>(item.storageValue),
                    icon: videoRemoteControlIcon(
                      item,
                      active: videoRemoteControlActive(item, nowPlaying),
                    ),
                    label: videoRemoteControlLabel(
                      item,
                      active: videoRemoteControlActive(item, nowPlaying),
                    ),
                    selected: videoRemoteControlActive(item, nowPlaying),
                    onPressed: enabled(item) ? () => onControl(item) : null,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 纯图标控制按钮：文字只进 tooltip 与无障碍语义；命中区恒 ≥48。开关类按钮
/// （收藏 / 字幕显隐）画选中态。
class _IconControl extends StatelessWidget {
  const _IconControl({
    required this.item,
    required this.nowPlaying,
    required this.onPressed,
  });

  final VideoRemoteControlItem item;
  final VideoRemoteNowPlaying nowPlaying;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool active = videoRemoteControlActive(item, nowPlaying);
    String label = videoRemoteControlLabel(item, active: active);
    if (item == VideoRemoteControlItem.speed) {
      label = '$label ${formatVideoRemoteSpeed(nowPlaying.speed)}';
    }
    final bool toggle =
        item == VideoRemoteControlItem.favorite ||
        item == VideoRemoteControlItem.subtitleVisibility;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: kVideoRemoteMinTapTarget,
        minHeight: kVideoRemoteMinTapTarget,
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: FushiIconButtonControl(
          key: ValueKey<String>('video-remote-control-${item.storageValue}'),
          tooltip: label,
          isSelected: toggle ? active : null,
          onPressed: onPressed,
          icon: FushiIcon(videoRemoteControlIcon(item, active: active)),
        ),
      ),
    );
  }
}

/// 横屏次组：按钮网格，每格 tonal 圆角块 = 图标 + 文字（大屏有地方，带字更好
/// 认）。开着的开关类按钮用 secondaryContainer 着色；按下缩放。
class _SecondaryGrid extends StatelessWidget {
  const _SecondaryGrid({
    required this.items,
    required this.width,
    required this.nowPlaying,
    required this.enabled,
    required this.onControl,
  });

  final List<VideoRemoteControlItem> items;
  final double width;
  final VideoRemoteNowPlaying nowPlaying;
  final bool Function(VideoRemoteControlItem item) enabled;
  final ValueChanged<VideoRemoteControlItem> onControl;

  @override
  Widget build(BuildContext context) {
    const double gap = 8;
    final int columns = width >= 380 ? 4 : 3;
    final double tile = math.max(
      kVideoRemoteMinTapTarget,
      (width - gap * (columns - 1)) / columns,
    );
    return Wrap(
      key: const ValueKey<String>('video-remote-secondary-grid'),
      spacing: gap,
      runSpacing: gap,
      children: <Widget>[
        for (final VideoRemoteControlItem item in items)
          SizedBox(
            width: tile,
            child: _GridTile(
              item: item,
              nowPlaying: nowPlaying,
              onPressed: enabled(item) ? () => onControl(item) : null,
            ),
          ),
      ],
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.item,
    required this.nowPlaying,
    required this.onPressed,
  });

  final VideoRemoteControlItem item;
  final VideoRemoteNowPlaying nowPlaying;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool active = videoRemoteControlActive(item, nowPlaying);
    final String label = item == VideoRemoteControlItem.speed
        ? formatVideoRemoteSpeed(nowPlaying.speed)
        : videoRemoteControlLabel(item, active: active);
    final String tooltip = item == VideoRemoteControlItem.speed
        ? '${t.playback_speed} $label'
        : label;
    final bool disabled = onPressed == null;
    final Color background = active
        ? cs.secondaryContainer
        : FushiDesignTokens.of(context).surfaces.overlay;
    final Color foreground = active
        ? cs.onSecondaryContainer
        : cs.onSurfaceVariant;
    final FushiMotionScheme motion = context.fushiMotion;
    return FushiTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled:
            item == VideoRemoteControlItem.favorite ||
                item == VideoRemoteControlItem.subtitleVisibility
            ? active
            : null,
        label: tooltip,
        excludeSemantics: true,
        child: FushiPressScale(
          enabled: !disabled,
          child: AnimatedContainer(
            duration: motion.effectsDefault.duration,
            curve: motion.effectsDefault.curve,
            decoration: BoxDecoration(
              color: disabled ? background.withValues(alpha: 0.38) : background,
              borderRadius: FushiM3eShape.cardRadius,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: ValueKey<String>(
                  'video-remote-control-${item.storageValue}',
                ),
                borderRadius: FushiM3eShape.cardRadius,
                onTap: onPressed,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: kVideoRemoteMinTapTarget + 24,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 10,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        FushiIcon(
                          videoRemoteControlIcon(item, active: active),
                          color: foreground,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          label,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: foreground,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 封面缩略图：光面海报材质简化档（用户 2026-10-26：圆角 + 内描边 + 轻光泽，
/// 无投影）；没有封面画 primaryContainer 底 + 视频图标。墨水屏退回描边框。
class _CoverThumb extends StatelessWidget {
  const _CoverThumb({required this.cover, required this.size});

  final ImageProvider? cover;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ImageProvider? image = cover;
    final int cache = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return SizedBox.square(
      dimension: size,
      child: ShelfCoverMaterialScope(
        material: ShelfCoverMaterial.glossyPoster,
        child: ShelfCoverFrame(
          density: ShelfCoverDensity.compact,
          backgroundColor: cs.primaryContainer,
          child: image == null
              ? ColoredBox(
                  color: cs.primaryContainer,
                  child: Center(
                    child: FushiIcon(
                      FushiIcons.video,
                      size: size * 0.45,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                )
              : Image(
                  image: ResizeImage.resizeIfNeeded(cache, null, image),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder:
                      (BuildContext context, Object error, StackTrace? stack) =>
                          ColoredBox(color: cs.primaryContainer),
                ),
        ),
      ),
    );
  }
}

/// 「已连接 电脑名」小胶囊。
class _HostChip extends StatelessWidget {
  const _HostChip({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return DecoratedBox(
      key: const ValueKey<String>('video-remote-host-chip'),
      decoration: ShapeDecoration(
        color: cs.secondaryContainer,
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(
              FushiIcons.laptop,
              size: 16,
              color: cs.onSecondaryContainer,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                t.video_remote_host_connected(name: name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 遥控卡的进度条：Apple 设计系统用 [FushiAppleSlider]（iOS 滑块，4px 细轨 +
/// 白圆钮），其余（MD3）用 M3E 的 [FushiWavySeekBar]（静态波形，不逐帧重建）。
///
/// 两者共用同一个 [FushiPlaybackClock]；Apple 分支每 250ms 轮询一次位置（与
/// 静态波形同节奏），拖动中显示本地值，松手才 [onSeek]。
class VideoRemoteSeekBar extends StatefulWidget {
  const VideoRemoteSeekBar({
    super.key,
    required this.clock,
    required this.isPlaying,
    required this.onSeek,
    required this.strokeWidth,
    required this.barHeight,
  });

  final FushiPlaybackClock clock;
  final bool isPlaying;
  final ValueChanged<Duration>? onSeek;
  final double strokeWidth;
  final double barHeight;

  @override
  State<VideoRemoteSeekBar> createState() => _VideoRemoteSeekBarState();
}

class _VideoRemoteSeekBarState extends State<VideoRemoteSeekBar> {
  Timer? _poll;

  /// 拖动中的比例（null = 跟随播放器）。
  double? _drag;

  /// 松手后播放器回报位置追上来之前先显示的目标比例。
  double? _pending;
  DateTime _pendingAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 250), (Timer _) {
      if (mounted && _drag == null) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  double _fraction() {
    final double? drag = _drag;
    if (drag != null) return drag;
    final int total = widget.clock.duration.inMilliseconds;
    final double live = total > 0
        ? (widget.clock.position.inMilliseconds / total).clamp(0.0, 1.0)
        : 0.0;
    final double? pending = _pending;
    if (pending != null) {
      final bool arrived = (live - pending).abs() < 0.01;
      final bool expired =
          DateTime.now().difference(_pendingAt) >
          const Duration(milliseconds: 1200);
      if (arrived || expired) {
        _pending = null;
      } else {
        return pending;
      }
    }
    return live;
  }

  void _commit(double fraction) {
    final ValueChanged<Duration>? onSeek = widget.onSeek;
    final int total = widget.clock.duration.inMilliseconds;
    setState(() {
      _drag = null;
      _pending = fraction;
      _pendingAt = DateTime.now();
    });
    if (onSeek != null && total > 0) {
      onSeek(Duration(milliseconds: (total * fraction).round()));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return FushiWavySeekBar(
        clock: widget.clock,
        isPlaying: widget.isPlaying,
        onSeek: widget.onSeek,
        strokeWidth: widget.strokeWidth,
        barHeight: widget.barHeight,
        animateWave: false,
        debugLabel: 'video-remote-seek',
      );
    }
    final Duration duration = widget.clock.duration;
    final double fraction = _fraction();
    final Duration shown = Duration(
      milliseconds: (duration.inMilliseconds * fraction).round(),
    );
    final TextStyle? timeStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );
    final bool seekable = widget.onSeek != null && duration > Duration.zero;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiAppleSlider(
          value: fraction,
          onChanged: seekable ? (double v) => setState(() => _drag = v) : null,
          onChangeEnd: seekable ? _commit : null,
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(formatFushiPlaybackTime(shown), style: timeStyle),
            Text(
              '-${formatFushiPlaybackTime(duration - shown)}',
              style: timeStyle,
            ),
          ],
        ),
      ],
    );
  }
}
