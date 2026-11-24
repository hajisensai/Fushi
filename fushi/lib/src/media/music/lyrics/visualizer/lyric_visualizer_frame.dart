/// 全屏歌词动画的逐帧驱动：一个 Ticker 每帧读插值时钟，把「歌词显示时间」和「墙钟秒数」
/// 交给 builder / painter。样式不自己建 Ticker，统一走这里，暂停与减弱动态效果的策略只写一次。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

/// 一帧的时间。
@immutable
class LyricVisualizerTick {
  const LyricVisualizerTick({
    required this.timeMs,
    required this.elapsed,
    this.dt = 0,
  });

  /// 歌词显示时间（毫秒，含偏移）。
  final int timeMs;

  /// 宿主挂上以来的墙钟秒数（暂停时也走，给漂移 / 粒子之类的闲置动画用；
  /// 减弱动态效果时恒为 0）。
  final double elapsed;

  /// 距上一帧的墙钟秒数（钳在 0–0.1，防切后台回来一大步；第一帧、减弱动态效果时为 0）。
  /// 给按帧积分的物理 / 平滑用，不用自己记上一帧时间。
  final double dt;
}

/// 逐帧可监听的时间源。CustomPainter 直接 `super(repaint: ticks)`，不必整树重建。
class LyricVisualizerTicks extends ChangeNotifier
    implements ValueListenable<LyricVisualizerTick> {
  LyricVisualizerTicks(this._value)
    : _timeMs = ValueNotifier<int>(_value.timeMs);

  LyricVisualizerTick _value;
  final ValueNotifier<int> _timeMs;

  @override
  LyricVisualizerTick get value => _value;

  /// 只在歌词时间变化时通知（暂停时闲置动画照走、这里不响）：只跟歌词走的轻样式 / 文字层挂这个，
  /// 省掉暂停时的逐帧重建。
  ValueListenable<int> get timeMs => _timeMs;

  set value(LyricVisualizerTick v) {
    if (v.timeMs == _value.timeMs && v.elapsed == _value.elapsed) return;
    _value = v;
    _timeMs.value = v.timeMs;
    notifyListeners();
  }

  /// 输入（参数 / 配色 / 字号…）变了而时间没动：照样通知一次，让 `repaint: ticks` 的画家重画。
  void forceNotify(LyricVisualizerTick v) {
    _value = v;
    _timeMs.value = v.timeMs;
    notifyListeners();
  }

  @override
  void dispose() {
    _timeMs.dispose();
    super.dispose();
  }
}

/// 驱动器：挂一个 Ticker，播放中或（开着动态效果且样式有闲置动画）时每帧推 [LyricVisualizerTicks]；
/// 其余时候停 Ticker，只在 [LyricVisualizerContext] 变化（拖进度 / 改偏移）时推一次。
class LyricVisualizerFrame extends StatefulWidget {
  const LyricVisualizerFrame({
    super.key,
    required this.context,
    required this.builder,
    this.idleAnimation = true,
  });

  final LyricVisualizerContext context;

  /// 画面是否用到墙钟（[LyricVisualizerTick.elapsed] / [LyricVisualizerTick.dt]：暂停时也走的漂移、粒子）。
  /// false = 画面只由歌词时间决定，暂停时 Ticker 停掉、不再逐帧要帧——不然整窗照刷新率重合成，
  /// 重样式（如花火）暂停时的 GPU 占用和播放中一样高。
  final bool idleAnimation;

  /// 只建一次（或在 [context] 变化时）；逐帧变化通过 [LyricVisualizerTicks] 传给 painter /
  /// `ValueListenableBuilder`。
  final Widget Function(BuildContext context, LyricVisualizerTicks ticks)
  builder;

  @override
  State<LyricVisualizerFrame> createState() => _LyricVisualizerFrameState();
}

class _LyricVisualizerFrameState extends State<LyricVisualizerFrame>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  late final LyricVisualizerTicks _ticks = LyricVisualizerTicks(_read(0));
  final Stopwatch _wall = Stopwatch()..start();
  double _lastElapsed = -1;

  LyricVisualizerTick _read(double elapsed) {
    final bool motion = widget.context.motion;
    final double dt = !motion || _lastElapsed < 0
        ? 0
        : (elapsed - _lastElapsed).clamp(0.0, 0.1);
    _lastElapsed = elapsed;
    return LyricVisualizerTick(
      timeMs: widget.context.displayTimeMs(),
      elapsed: motion ? elapsed : 0,
      dt: dt,
    );
  }

  void _onTick(Duration _) {
    _ticks.value = _read(_wall.elapsedMicroseconds / 1e6);
  }

  bool get _wantsTicker =>
      widget.context.playing || (widget.context.motion && widget.idleAnimation);

  void _sync() {
    if (_wantsTicker) {
      if (!_ticker.isActive) unawaited(_ticker.start());
    } else {
      if (_ticker.isActive) _ticker.stop();
      _onTick(Duration.zero);
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant LyricVisualizerFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
    _ticks.forceNotify(_read(_wall.elapsedMicroseconds / 1e6));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _ticks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _ticks);
}

/// 便捷：每帧整棵重建（简单样式用；重的样式应走 CustomPainter + `repaint: ticks`）。
class LyricVisualizerFrameBuilder extends StatelessWidget {
  const LyricVisualizerFrameBuilder({
    super.key,
    required this.context,
    required this.builder,
  });

  final LyricVisualizerContext context;
  final Widget Function(BuildContext context, LyricVisualizerTick tick) builder;

  @override
  Widget build(BuildContext buildContext) => LyricVisualizerFrame(
    context: context,
    builder: (BuildContext c, LyricVisualizerTicks ticks) =>
        ValueListenableBuilder<LyricVisualizerTick>(
          valueListenable: ticks,
          builder: (BuildContext c, LyricVisualizerTick tick, Widget? _) =>
              builder(c, tick),
        ),
  );
}
