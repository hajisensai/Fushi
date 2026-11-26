import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_apple_seek_glyph.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
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
/// - Material（M3E）：波浪进度条 + 形变播放键 + 短 / 长步进 tonal 圆钮（圆钮下标
///   「−Ns / +Ns」，与视频控制条的步进键同一种标注）。
/// - Apple：iOS 细轨滑块 + 圆钮，步进键画 [VideoAppleSeekGlyph]（圆箭头里写着秒数），
///   底色取系统分组灰（实色，不上玻璃）。
///
/// 步进秒数不写死：短步进 [seekSeconds]、长步进 [longSeekSeconds]，由视频页从
/// asbplayer 配置（与控制条 / 快捷键同一份）传入。
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
    required this.seekSeconds,
    required this.longSeekSeconds,
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

  /// 短步进秒数（asbplayer `seekSeconds`）。
  final int seekSeconds;

  /// 长步进秒数（asbplayer `longSeekSeconds`）。
  final int longSeekSeconds;

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
                  _MaterialSeekStepButton(
                    panel: panel,
                    forward: false,
                    long: true,
                  ),
                  _MaterialSeekStepButton(
                    panel: panel,
                    forward: false,
                    long: false,
                  ),
                  FushiExpressivePlayButton(
                    isPlaying: playing,
                    size: 64,
                    onPressed: panel.onPlayPause,
                  ),
                  _MaterialSeekStepButton(
                    panel: panel,
                    forward: true,
                    long: false,
                  ),
                  _MaterialSeekStepButton(
                    panel: panel,
                    forward: true,
                    long: true,
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
                  _appleSeekStep(panel, apple, forward: false, long: true),
                  const SizedBox(width: 16),
                  _appleSeekStep(panel, apple, forward: false, long: false),
                  const SizedBox(width: 16),
                  _AppleRoundButton(
                    key: const ValueKey<String>('video_tabletop_play_button'),
                    glyph: FushiIcon(
                      FushiIcons.filled(
                        playing ? FushiIcons.pause : FushiIcons.play,
                      ),
                      size: 30,
                      color: apple.onAccent,
                    ),
                    diameter: 64,
                    tooltip: playing ? t.pause : t.play,
                    background: apple.accent,
                    onPressed: panel.onPlayPause,
                  ),
                  const SizedBox(width: 16),
                  _appleSeekStep(panel, apple, forward: true, long: false),
                  const SizedBox(width: 16),
                  _appleSeekStep(panel, apple, forward: true, long: true),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 步进键的 key：短步进沿用旧 key（`video_tabletop_seek_*_button`），长步进加 `long_`。
ValueKey<String> _seekStepKey({required bool forward, required bool long}) =>
    ValueKey<String>(
      'video_tabletop_${long ? 'long_' : ''}seek_'
      '${forward ? 'forward' : 'back'}_button',
    );

int _seekStepSeconds(VideoTabletopPanel panel, {required bool long}) =>
    long ? panel.longSeekSeconds : panel.seekSeconds;

String _seekStepTooltip(int seconds, {required bool forward}) => forward
    ? t.video_control_seek_forward_seconds(seconds: seconds)
    : t.video_control_seek_backward_seconds(seconds: seconds);

/// Apple 面板的一颗步进圆钮：圆箭头里写着当前秒数（[VideoAppleSeekGlyph]）。
Widget _appleSeekStep(
  VideoTabletopPanel panel,
  FushiAppleColors apple, {
  required bool forward,
  required bool long,
}) {
  final int seconds = _seekStepSeconds(panel, long: long);
  return _AppleRoundButton(
    key: _seekStepKey(forward: forward, long: long),
    glyph: VideoAppleSeekGlyph(
      forward: forward,
      seconds: seconds,
      size: 24,
      color: apple.label,
    ),
    diameter: 48,
    tooltip: _seekStepTooltip(seconds, forward: forward),
    background: apple.tertiaryFill,
    onPressed: () => panel.onSeekRelative(forward ? seconds : -seconds),
  );
}

/// M3E 面板的一颗步进键：tonal 圆钮（短步进快退 / 快进图标，长步进双箭头）+ 圆钮下
/// 「−Ns / +Ns」标注，秒数随配置变。
class _MaterialSeekStepButton extends StatelessWidget {
  const _MaterialSeekStepButton({
    required this.panel,
    required this.forward,
    required this.long,
  });

  final VideoTabletopPanel panel;
  final bool forward;
  final bool long;

  @override
  Widget build(BuildContext context) {
    final int seconds = _seekStepSeconds(panel, long: long);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final IconData icon = long
        ? (forward
              ? FushiIcons.doubleChevronRight
              : FushiIcons.doubleChevronLeft)
        : (forward ? FushiIcons.fastForward : FushiIcons.fastRewind);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiIconButtonControl.filledTonal(
          key: _seekStepKey(forward: forward, long: long),
          size: ButtonSizeVariant.small,
          tooltip: _seekStepTooltip(seconds, forward: forward),
          onPressed: () => panel.onSeekRelative(forward ? seconds : -seconds),
          icon: FushiIcon(icon),
        ),
        Text(
          forward
              ? t.video_bottom_seek_forward_seconds_label(seconds: seconds)
              : t.video_bottom_seek_back_seconds_label(seconds: seconds),
          style: context.fushiType.labelSmall.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _AppleRoundButton extends StatelessWidget {
  const _AppleRoundButton({
    required this.glyph,
    required this.diameter,
    required this.tooltip,
    required this.background,
    required this.onPressed,
    super.key,
  });

  final Widget glyph;
  final double diameter;
  final String tooltip;
  final Color background;
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
                child: Center(child: glyph),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
