// 网页视频（底层合成档）的底部控制栏：与原生播放器同一套 M3E 部件（进度轨道、播放 /
// 快退快进键、时间、浮动胶囊、底部暗角），动作全部交给页面 JS 驱动的站点播放器。
//
// 原生播放器的控制条长在 media_kit fork 里、直接绑 `Player`（网页视频没有），所以这里
// 只复用纯参数驱动的部件，显隐 / 拖动 / 悬停自己管：鼠标一动显出，停 2.5 s 收起（连同
// 指针），暂停 / 拖动 / 菜单打开时常显。悬停检测不吃点击——下面的字幕点词与点画面切
// 播放照常。
import 'dart:async';

import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show VideoSeekBarVisual;

import 'package:fushi/src/media/video/video_m3e_chrome.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 倍速菜单的档位（与原生播放器常用档一致）。
const List<double> kWebVideoRates = <double>[0.5, 0.75, 1, 1.25, 1.5, 2];

class WebVideoControls extends StatefulWidget {
  const WebVideoControls({
    super.key,
    required this.playback,
    required this.rate,
    required this.volume,
    required this.muted,
    required this.fullscreen,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onSeekRelative,
    required this.onRate,
    required this.onVolume,
    required this.onToggleMute,
    required this.onToggleFullscreen,
    this.visibility,
  });

  /// 位置 / 时长 / 播放态的来源（页面 JS 经 applyExternalPlaybackState 注入）。
  final VideoPlayerController playback;
  final double rate;
  final double volume;
  final bool muted;
  final bool fullscreen;
  final VoidCallback onTogglePlay;
  final ValueChanged<int> onSeek;
  final ValueChanged<int> onSeekRelative;
  final ValueChanged<double> onRate;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleFullscreen;

  /// 可选：外部读控制栏显隐（顶栏跟着一起收）。
  final ValueNotifier<bool>? visibility;

  @override
  State<WebVideoControls> createState() => _WebVideoControlsState();
}

class _WebVideoControlsState extends State<WebVideoControls> {
  static const double _extent = 40;
  static const double _trackHeight = 36;
  static const Duration _hideAfter = Duration(milliseconds: 2500);

  late final ValueNotifier<bool> _visible =
      widget.visibility ?? ValueNotifier<bool>(true);
  Timer? _hideTimer;
  bool _menuOpen = false;
  bool _showRemaining = false;

  /// 进度轨道交互：拖动 / 悬停时显示的比例（null = 跟播放位置）。
  double? _dragFraction;
  double? _hoverFraction;

  @override
  void initState() {
    super.initState();
    widget.playback.addListener(_onPlayback);
    _poke();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.playback.removeListener(_onPlayback);
    if (widget.visibility == null) _visible.dispose();
    super.dispose();
  }

  bool get _pinned =>
      !widget.playback.isPlaying || _dragFraction != null || _menuOpen;

  void _onPlayback() {
    if (_pinned) _show();
    if (mounted) setState(() {});
  }

  void _show() {
    _hideTimer?.cancel();
    if (!_visible.value) _visible.value = true;
  }

  /// 鼠标动了 / 点了控件：显出并重新计时。
  void _poke() {
    _show();
    _hideTimer = Timer(_hideAfter, () {
      if (!mounted || _pinned) return;
      _visible.value = false;
    });
  }

  double _fractionAt(Offset local, double width) =>
      width <= 0 ? 0 : (local.dx / width).clamp(0.0, 1.0);

  void _commitSeek(double fraction) {
    final int dur = widget.playback.durationMs ?? 0;
    if (dur > 0) widget.onSeek((fraction * dur).round());
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // 只听悬停，不挡下面的点击（字幕点词、点画面切播放）。
      hitTestBehavior: HitTestBehavior.translucent,
      opaque: false,
      onHover: (_) => _poke(),
      child: ValueListenableBuilder<bool>(
        valueListenable: _visible,
        builder: (BuildContext context, bool visible, Widget? _) {
          return MouseRegion(
            hitTestBehavior: HitTestBehavior.translucent,
            opaque: false,
            cursor: visible ? MouseCursor.defer : SystemMouseCursors.none,
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: VideoM3eBottomScrim(
                    visible: _visible,
                    duration: FushiMotion.short,
                    height: 160,
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 16,
                  child: IgnorePointer(
                    ignoring: !visible,
                    child: AnimatedOpacity(
                      opacity: visible ? 1 : 0,
                      duration: FushiMotion.short,
                      child: _buildBar(context),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBar(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color fg = videoM3eChromeForegroundOf(context);
    final VideoPlayerController p = widget.playback;
    final int durMs = p.durationMs ?? 0;
    final int posMs = p.positionMs ?? 0;
    final Duration duration = Duration(milliseconds: durMs);
    final double playedFraction = durMs > 0
        ? (posMs / durMs).clamp(0.0, 1.0)
        : 0;
    final double shown = _dragFraction ?? playedFraction;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: _trackHeight,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final double w = c.maxWidth;
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                onHover: (PointerHoverEvent e) => setState(
                  () => _hoverFraction = _fractionAt(e.localPosition, w),
                ),
                onExit: (_) => setState(() => _hoverFraction = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (TapUpDetails d) {
                    _commitSeek(_fractionAt(d.localPosition, w));
                    _poke();
                  },
                  onHorizontalDragStart: (DragStartDetails d) => setState(
                    () => _dragFraction = _fractionAt(d.localPosition, w),
                  ),
                  onHorizontalDragUpdate: (DragUpdateDetails d) => setState(
                    () => _dragFraction = _fractionAt(d.localPosition, w),
                  ),
                  onHorizontalDragEnd: (_) {
                    final double? f = _dragFraction;
                    setState(() => _dragFraction = null);
                    if (f != null) _commitSeek(f);
                    _poke();
                  },
                  child: VideoM3eSeekTrack(
                    visual: VideoSeekBarVisual(
                      position: shown,
                      buffer: shown,
                      hover: _dragFraction ?? _hoverFraction,
                      hovering: _hoverFraction != null,
                      dragging: _dragFraction != null,
                      playing: p.isPlaying,
                      duration: duration,
                      alignment: Alignment.center,
                    ),
                    color: cs.primary,
                    scale: 1,
                    hoverBubble: true,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        VideoM3eFloatingSurface(
          enabled: true,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: <Widget>[
              VideoM3eSeekButton(
                forward: false,
                seconds: 10,
                extent: _extent,
                onPressed: () {
                  widget.onSeekRelative(-10000);
                  _poke();
                },
              ),
              const SizedBox(width: 4),
              VideoM3ePlayPauseButton(
                playing: p.isPlaying,
                extent: _extent,
                onPressed: () {
                  widget.onTogglePlay();
                  _poke();
                },
              ),
              const SizedBox(width: 4),
              VideoM3eSeekButton(
                forward: true,
                seconds: 10,
                extent: _extent,
                onPressed: () {
                  widget.onSeekRelative(10000);
                  _poke();
                },
              ),
              const SizedBox(width: 12),
              VideoM3eTimeText(
                position: Duration(
                  milliseconds: (_dragFraction != null && durMs > 0)
                      ? (_dragFraction! * durMs).round()
                      : posMs,
                ),
                duration: duration,
                showRemaining: _showRemaining,
                onToggle: () =>
                    setState(() => _showRemaining = !_showRemaining),
                style: TextStyle(
                  color: fg,
                  fontSize: 14,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              const Spacer(),
              _rateButton(fg),
              const SizedBox(width: 4),
              _volumeControl(fg),
              const SizedBox(width: 4),
              VideoM3eIconButton(
                extent: _extent,
                icon: FushiIcon(
                  widget.fullscreen
                      ? FushiIcons.fullscreenExit
                      : FushiIcons.fullscreen,
                ),
                onPressed: () {
                  widget.onToggleFullscreen();
                  _poke();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _rateButton(Color fg) {
    final String label = widget.rate == widget.rate.roundToDouble()
        ? '${widget.rate.toStringAsFixed(0)}x'
        : '${widget.rate}x';
    return PopupMenuButton<double>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onOpened: () => setState(() => _menuOpen = true),
      onCanceled: () {
        setState(() => _menuOpen = false);
        _poke();
      },
      onSelected: (double r) {
        setState(() => _menuOpen = false);
        widget.onRate(r);
        _poke();
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<double>>[
        for (final double r in kWebVideoRates)
          CheckedPopupMenuItem<double>(
            value: r,
            checked: (r - widget.rate).abs() < 0.01,
            child: Text('${r}x'),
          ),
      ],
      child: SizedBox(
        height: _extent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Center(
            child: Text(
              label,
              style: TextStyle(color: fg, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }

  Widget _volumeControl(Color fg) {
    final double shown = widget.muted ? 0 : widget.volume;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        VideoM3eIconButton(
          extent: _extent,
          icon: FushiIcon(
            shown == 0 ? FushiIcons.volumeOff : FushiIcons.volumeUp,
          ),
          onPressed: () {
            widget.onToggleMute();
            _poke();
          },
        ),
        SizedBox(
          width: 96,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: shown.clamp(0.0, 1.0),
              onChanged: (double v) {
                widget.onVolume(v);
                _poke();
              },
            ),
          ),
        ),
      ],
    );
  }
}
