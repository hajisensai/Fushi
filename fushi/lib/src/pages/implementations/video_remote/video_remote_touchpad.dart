import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_remote_touchpad_gestures.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 触控板上的一次操作（页面把它翻译成遥控命令）。
enum VideoRemotePadAction {
  playPause,
  replayLine,
  previousLine,
  nextLine,
  volumeUp,
  volumeDown,
}

/// 手势 → 操作（纯函数）：整屏点按播放 / 暂停，双击重听这句，左滑下一句、右滑
/// 上一句（像翻页：手指往左推 = 往后），上滑 / 下滑调音量。其余手势不处理。
VideoRemotePadAction? videoRemotePadActionFor(VideoRemotePadGesture gesture) =>
    switch (gesture) {
      VideoRemotePadGesture.tap => VideoRemotePadAction.playPause,
      VideoRemotePadGesture.doubleTap => VideoRemotePadAction.replayLine,
      VideoRemotePadGesture.flickLeft => VideoRemotePadAction.nextLine,
      VideoRemotePadGesture.flickRight => VideoRemotePadAction.previousLine,
      VideoRemotePadGesture.flickUp => VideoRemotePadAction.volumeUp,
      VideoRemotePadGesture.flickDown => VideoRemotePadAction.volumeDown,
      _ => null,
    };

/// 手机遥控的「触控板」：整块屏幕都是操作区，不看手机也能按（不存在按偏的
/// 按钮）。每个被识别的手势震一下并在中央闪出对应图标，眼睛回到电脑屏幕前也
/// 知道按成了什么。
///
/// 只负责识别与反馈；[onAction] 返回 false 表示这一下当前做不了（例如电脑不支持
/// 音量），不震、不闪图标。
class VideoRemoteTouchpad extends StatefulWidget {
  const VideoRemoteTouchpad({
    super.key,
    required this.line,
    required this.playing,
    required this.onAction,
    required this.onExit,
  });

  /// 电脑上当前这句字幕（低头看一眼时用）；空 = 不显示。
  final String line;
  final bool playing;
  final bool Function(VideoRemotePadAction action) onAction;
  final VoidCallback onExit;

  @override
  State<VideoRemoteTouchpad> createState() => _VideoRemoteTouchpadState();
}

class _VideoRemoteTouchpadState extends State<VideoRemoteTouchpad>
    with SingleTickerProviderStateMixin {
  final VideoRemotePadGestureTracker _tracker = VideoRemotePadGestureTracker();

  /// 只在有手指按着 / 单击等确认时跑，推进长按与双击窗口的时间。手势时钟就是
  /// 它的帧时间累计（停下时把这段并进 [_offset]）：指针事件取最近一帧的时刻，
  /// 精度一帧，对几百毫秒的判别窗口足够；测试里随 `pump` 前进，与真机同一套。
  late final Ticker _ticker = createTicker(_onTick);
  Duration _offset = Duration.zero;
  Duration _tickerElapsed = Duration.zero;

  /// 中央闪现的上一次操作的图标（发出时定下：播放中点一下闪「暂停」，之后
  /// 播放态翻转也不跟着变；换 key 让 AnimatedSwitcher 每次都重放）。
  IconData? _flash;
  int _flashSerial = 0;
  Timer? _flashTimer;

  @override
  void dispose() {
    _ticker.dispose();
    _flashTimer?.cancel();
    super.dispose();
  }

  Duration get _now => _offset + _tickerElapsed;

  void _onTick(Duration elapsed) {
    _tickerElapsed = elapsed;
    _emit(_tracker.tick(_now));
    if (!_tracker.busy && _ticker.isActive) {
      _offset += _tickerElapsed;
      _tickerElapsed = Duration.zero;
      _ticker.stop();
    }
  }

  void _wake() {
    if (_tracker.busy && !_ticker.isActive) _ticker.start();
  }

  void _emit(List<VideoRemotePadGesture> gestures) {
    for (final VideoRemotePadGesture gesture in gestures) {
      final VideoRemotePadAction? action = videoRemotePadActionFor(gesture);
      if (action == null) continue;
      final IconData icon = _iconFor(action);
      if (!widget.onAction(action)) continue;
      fushiLiftHaptic(context);
      _flashTimer?.cancel();
      setState(() {
        _flash = icon;
        _flashSerial++;
      });
      _flashTimer = Timer(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _flash = null);
      });
    }
  }

  IconData _iconFor(VideoRemotePadAction action) => switch (action) {
    VideoRemotePadAction.playPause =>
      widget.playing ? FushiIcons.pause : FushiIcons.play,
    VideoRemotePadAction.replayLine => FushiIcons.replay,
    VideoRemotePadAction.previousLine => FushiIcons.skipPrevious,
    VideoRemotePadAction.nextLine => FushiIcons.skipNext,
    VideoRemotePadAction.volumeUp => FushiIcons.volumeUp,
    VideoRemotePadAction.volumeDown => FushiIcons.volumeDown,
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    final Duration switchDuration = fushiMotionDuration(
      context,
      const Duration(milliseconds: 180),
    );
    final IconData? flash = _flash;
    return Material(
      key: const ValueKey<String>('video-remote-touchpad'),
      color: scheme.surfaceContainerLowest,
      child: FushiEntranceScope(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Listener(
              key: const ValueKey<String>('video-remote-touchpad-surface'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (PointerDownEvent e) {
                _emit(_tracker.down(e.pointer, e.position, _now));
                _wake();
              },
              onPointerMove: (PointerMoveEvent e) =>
                  _emit(_tracker.move(e.pointer, e.position, _now)),
              onPointerUp: (PointerUpEvent e) {
                _emit(_tracker.up(e.pointer, _now));
                _wake();
              },
              onPointerCancel: (PointerCancelEvent e) =>
                  _tracker.cancel(e.pointer),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  safe.top + 88,
                  24,
                  safe.bottom + 24,
                ),
                child: Column(
                  children: <Widget>[
                    Expanded(
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: switchDuration,
                          transitionBuilder:
                              (Widget child, Animation<double> animation) =>
                                  ScaleTransition(
                                    scale: Tween<double>(
                                      begin: 0.8,
                                      end: 1,
                                    ).animate(animation),
                                    child: FadeTransition(
                                      opacity: animation,
                                      child: child,
                                    ),
                                  ),
                          child: flash == null
                              ? FushiStaggeredEntrance(
                                  key: const ValueKey<String>('idle'),
                                  index: 1,
                                  child: Text(
                                    widget.line,
                                    key: const ValueKey<String>(
                                      'video-remote-touchpad-line',
                                    ),
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                )
                              : Container(
                                  key: ValueKey<int>(_flashSerial),
                                  width: 112,
                                  height: 112,
                                  decoration: BoxDecoration(
                                    color: scheme.primaryContainer,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Center(
                                    child: FushiIcon(
                                      flash,
                                      key: const ValueKey<String>(
                                        'video-remote-touchpad-flash',
                                      ),
                                      size: 56,
                                      color: scheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                    FushiStaggeredEntrance(
                      index: 2,
                      child: Text(
                        t.video_remote_touchpad_hint,
                        key: const ValueKey<String>(
                          'video-remote-touchpad-hint',
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: safe.top + 8,
              left: safe.left + 8,
              right: safe.right + 8,
              child: FushiStaggeredEntrance(
                index: 0,
                child: FushiFloatingTopBar(
                  key: const ValueKey<String>('video-remote-touchpad-top-bar'),
                  leading: <FushiToolbarItem>[
                    FushiToolbarItem(
                      key: const ValueKey<String>('video-remote-touchpad-exit'),
                      icon: FushiIcons.close,
                      label: t.video_remote_touchpad_exit,
                      onPressed: widget.onExit,
                    ),
                  ],
                  title: t.video_remote_touchpad,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
