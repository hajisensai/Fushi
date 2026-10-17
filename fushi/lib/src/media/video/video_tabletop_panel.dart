import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 桌面姿态（折叠屏半开平放、横向折痕）下视频页**下半屏**的播放控制面板。
///
/// 画面连同原播放器控件 / 字幕留在折痕上方（见 `FushiTabletopSplit`），这块面板
/// 常驻在平放的下半屏，不随控件自动隐藏——对齐 Android「Make your app fold aware」
/// 指南的桌面模式媒体播放器。
///
/// 两套设计系统各自成套：
/// - Material（M3E）：波浪进度条 + 形变播放键 + ±10 秒 tonal 圆钮（与歌词模式 /
///   字幕遥控器同一套 `fushi_m3e_player` 公共件）。
/// - Apple：iOS 细轨滑块 + SF 实心字形圆钮（语义图标 [FushiIcons] 经 [FushiIcon]
///   按设计系统换字形），底色取系统分组灰（实色，不上玻璃）。
///
/// 不认识播放器对象：位置经 [position] / [duration] 读，操作全是回调，[listenable]
/// 通知播放态变化，[positionListenable] 推送位置变化——两套设计系统都由它驱动进度，
/// 不起轮询定时器。
class VideoTabletopPanel extends StatelessWidget {
  const VideoTabletopPanel({
    required this.listenable,
    required this.positionListenable,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.onPlayPause,
    required this.onSeek,
    required this.onSeekRelative,
    super.key,
    this.title,
  });

  /// 播放态 / 时长变化时通知重建整块面板。
  final Listenable listenable;

  /// 播放位置变化时通知（只重读进度条 / 时间，不重建整块面板）。生产接
  /// `VideoPlayerController.positionMsListenable`。
  final Listenable positionListenable;
  final bool Function() isPlaying;
  final Duration Function() position;
  final Duration Function() duration;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;

  /// 相对跳转（秒，负数后退）。
  final ValueChanged<int> onSeekRelative;

  /// 当前标题（随 [listenable] 重读）；null / 空串不显示。
  final String? Function()? title;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: listenable,
      builder: (BuildContext context, _) => isGlassDesign(context)
          ? _AppleTabletopPanel(panel: this)
          : _MaterialTabletopPanel(panel: this),
    );
  }
}

class _PanelClock implements FushiPlaybackClock {
  const _PanelClock(this._panel);

  final VideoTabletopPanel _panel;

  @override
  Duration get position => _panel.position();

  @override
  Duration get duration => _panel.duration();
}

class _MaterialTabletopPanel extends StatelessWidget {
  const _MaterialTabletopPanel({required this.panel});

  final VideoTabletopPanel panel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool playing = panel.isPlaying();
    final String? title = panel.title?.call();
    return Material(
      key: const ValueKey<String>('video_tabletop_panel_material'),
      color: cs.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (title != null && title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.titleMediumEmphasized.copyWith(
                      color: cs.onSurface,
                    ),
                  ),
                ),
              FushiWavySeekBar(
                clock: _PanelClock(panel),
                isPlaying: playing,
                onSeek: panel.onSeek,
                clockListenable: panel.positionListenable,
                strokeWidth: 4,
                barHeight: 28,
                animateWave: false,
                debugLabel: 'video-tabletop-seek',
              ),
              const SizedBox(height: 8),
              FushiButtonGroup(
                spacing: 12,
                children: <Widget>[
                  fushiRelativeSeekButton(
                    -10,
                    panel.onSeekRelative,
                    keyPrefix: 'video_tabletop',
                  ),
                  FushiExpressivePlayButton(
                    isPlaying: playing,
                    size: 64,
                    onPressed: panel.onPlayPause,
                  ),
                  fushiRelativeSeekButton(
                    10,
                    panel.onSeekRelative,
                    keyPrefix: 'video_tabletop',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppleTabletopPanel extends StatefulWidget {
  const _AppleTabletopPanel({required this.panel});

  final VideoTabletopPanel panel;

  @override
  State<_AppleTabletopPanel> createState() => _AppleTabletopPanelState();
}

class _AppleTabletopPanelState extends State<_AppleTabletopPanel> {
  /// 拖动中的目标位置（毫秒）；null = 跟随播放位置。
  double? _dragMs;

  @override
  void initState() {
    super.initState();
    widget.panel.positionListenable.addListener(_onPositionChanged);
  }

  @override
  void didUpdateWidget(_AppleTabletopPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Listenable previous = oldWidget.panel.positionListenable;
    final Listenable next = widget.panel.positionListenable;
    if (!identical(previous, next)) {
      previous.removeListener(_onPositionChanged);
      next.addListener(_onPositionChanged);
    }
  }

  /// 位置推送：拖动中滑块跟手指，不被播放位置拽回。
  void _onPositionChanged() {
    if (mounted && _dragMs == null) setState(() {});
  }

  @override
  void dispose() {
    widget.panel.positionListenable.removeListener(_onPositionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final VideoTabletopPanel panel = widget.panel;
    final bool playing = panel.isPlaying();
    final String? title = panel.title?.call();
    final double durationMs = panel.duration().inMilliseconds.toDouble().clamp(
      0,
      double.infinity,
    );
    final double positionMs =
        (_dragMs ?? panel.position().inMilliseconds.toDouble()).clamp(
          0,
          durationMs <= 0 ? 0 : durationMs,
        );
    final TextStyle timeStyle = context.fushiType.labelSmall.copyWith(
      color: apple.secondaryLabel,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return ColoredBox(
      key: const ValueKey<String>('video_tabletop_panel_apple'),
      color: apple.secondaryGroupedBackground,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (title != null && title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.titleMediumEmphasized.copyWith(
                      color: apple.label,
                    ),
                  ),
                ),
              adaptiveSlider(
                context: context,
                value: positionMs,
                max: durationMs <= 0 ? 1 : durationMs,
                onChanged: durationMs <= 0
                    ? null
                    : (double v) => setState(() => _dragMs = v),
                onChangeEnd: (double v) {
                  panel.onSeek(Duration(milliseconds: v.round()));
                  setState(() => _dragMs = null);
                },
              ),
              Row(
                children: <Widget>[
                  Text(
                    formatFushiPlaybackTime(
                      Duration(milliseconds: positionMs.round()),
                    ),
                    style: timeStyle,
                  ),
                  const Spacer(),
                  Text(
                    '-${formatFushiPlaybackTime(Duration(milliseconds: (durationMs - positionMs).round()))}',
                    style: timeStyle,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _AppleRoundButton(
                    key: const ValueKey<String>(
                      'video_tabletop_seek_back_button',
                    ),
                    icon: FushiIcons.replay10,
                    diameter: 48,
                    iconSize: 24,
                    tooltip: t.video_control_seek_backward,
                    background: apple.tertiaryFill,
                    foreground: apple.label,
                    onPressed: () => panel.onSeekRelative(-10),
                  ),
                  const SizedBox(width: 24),
                  _AppleRoundButton(
                    key: const ValueKey<String>('video_tabletop_play_button'),
                    icon: FushiIcons.filled(
                      playing ? FushiIcons.pause : FushiIcons.play,
                    ),
                    diameter: 64,
                    iconSize: 30,
                    tooltip: playing ? t.pause : t.play,
                    background: apple.accent,
                    foreground: apple.onAccent,
                    onPressed: panel.onPlayPause,
                  ),
                  const SizedBox(width: 24),
                  _AppleRoundButton(
                    key: const ValueKey<String>(
                      'video_tabletop_seek_forward_button',
                    ),
                    icon: FushiIcons.forward10,
                    diameter: 48,
                    iconSize: 24,
                    tooltip: t.video_control_seek_forward,
                    background: apple.tertiaryFill,
                    foreground: apple.label,
                    onPressed: () => panel.onSeekRelative(10),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppleRoundButton extends StatelessWidget {
  const _AppleRoundButton({
    required this.icon,
    required this.diameter,
    required this.iconSize,
    required this.tooltip,
    required this.background,
    required this.foreground,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final double diameter;
  final double iconSize;
  final String tooltip;
  final Color background;
  final Color foreground;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FushiTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: FushiPressScale(
          child: Material(
            color: background,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox.square(
                dimension: diameter,
                child: FushiIcon(icon, size: iconSize, color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
