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
  const LyricVisualizerTick({required this.timeMs, required this.elapsed});

  /// 歌词显示时间（毫秒，含偏移）。
  final int timeMs;

  /// 宿主挂上以来的墙钟秒数（暂停时也走，给漂移 / 粒子之类的闲置动画用；
  /// 减弱动态效果时恒为 0）。
  final double elapsed;
}

/// 逐帧可监听的时间源。CustomPainter 直接 `super(repaint: ticks)`，不必整树重建。
class LyricVisualizerTicks extends ChangeNotifier
    implements ValueListenable<LyricVisualizerTick> {
  LyricVisualizerTicks(this._value);

  LyricVisualizerTick _value;

  @override
  LyricVisualizerTick get value => _value;

  set value(LyricVisualizerTick v) {
    if (v.timeMs == _value.timeMs && v.elapsed == _value.elapsed) return;
    _value = v;
    notifyListeners();
  }

  /// 输入（参数 / 配色 / 字号…）变了而时间没动：照样通知一次，让 `repaint: ticks` 的画家重画。
  void forceNotify(LyricVisualizerTick v) {
    _value = v;
    notifyListeners();
  }
}

/// 驱动器：挂一个 Ticker，播放中或开着动态效果时每帧推 [LyricVisualizerTicks]；
/// 暂停 + 减弱动态效果时停 Ticker，只在 [LyricVisualizerContext] 变化（拖进度 / 改偏移）时推一次。
class LyricVisualizerFrame extends StatefulWidget {
  const LyricVisualizerFrame({
    super.key,
    required this.context,
    required this.builder,
  });

  final LyricVisualizerContext context;

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

  LyricVisualizerTick _read(double elapsed) => LyricVisualizerTick(
    timeMs: widget.context.displayTimeMs(),
    elapsed: widget.context.motion ? elapsed : 0,
  );

  void _onTick(Duration _) {
    _ticks.value = _read(_wall.elapsedMicroseconds / 1e6);
  }

  bool get _wantsTicker => widget.context.playing || widget.context.motion;

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
