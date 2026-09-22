import 'dart:async';

import 'package:flutter/widgets.dart';

/// 播放位置 / 总时长 → `0..1` 的进度比例。纯函数，组件与测试同源。
///
/// 三种「没有进度可言」的形状统一归 0，而不是让调用方各自判空：未 load
/// （position 为 null）、媒体头还没解析出时长（duration 为 null）、直播流
/// （duration 恒 0，除不得）。超出 `[0, 1]` 的值一律钳制——seek 在途时
/// media_kit 的 position 会短暂越过 duration，不钳制会画出一条超出轨道的线。
double videoSlimProgressFraction({
  required int? positionMs,
  required int? durationMs,
}) {
  if (positionMs == null || durationMs == null || durationMs <= 0) return 0;
  return (positionMs / durationMs).clamp(0.0, 1.0);
}

/// 视频最下方那条主题色细进度条（B 站 / YouTube 在控制条淡出后留下的那条线）。
///
/// 刻意**不**接 [VideoPlayerController] 而只收两个取值回调：controller 的
/// `notifyListeners` 是按「当前字幕 cue 变化」节流的（见其 125ms tick 注释），
/// 拿它驱动进度条会得到一条一句一跳的线；反过来让 controller 逐帧通知，
/// 整页 5000 行的监听者都要跟着重建。故本组件自己按 [refreshInterval] 轮询，
/// 且只在比例真的变了才 setState——一条 3 像素高的线，200ms 一跳肉眼即连续。
///
/// 回调形态还让它可以被纯 widget 测试驱动（无需真 libmpv）。
class VideoSlimProgressBar extends StatefulWidget {
  const VideoSlimProgressBar({
    required this.positionMs,
    required this.durationMs,
    required this.color,
    this.height = 3,
    this.trackColor,
    this.refreshInterval = const Duration(milliseconds: 200),
    super.key,
  });

  /// 当前播放位置（毫秒）取值器；null = 未 load。
  final ValueGetter<int?> positionMs;

  /// 媒体总时长（毫秒）取值器；null / <= 0 = 不可知（直播流）。
  final ValueGetter<int?> durationMs;

  /// 已播段颜色。播放器 chrome 压在固定深色 scrim 上，调用方必须传
  /// `videoChromeAccentColor(colorScheme)` 而不是裸 `colorScheme.primary`
  /// （浅色主题下 primary 是深色，压深色 scrim 黑压黑不可读）。
  final Color color;

  /// 未播段（轨道）颜色；null 时取 [color] 的低不透明度版本。
  final Color? trackColor;

  /// 线高（逻辑像素）。默认 3：够看见、又不至于在小窗里喧宾夺主。
  final double height;

  /// 轮询间隔。
  final Duration refreshInterval;

  @override
  State<VideoSlimProgressBar> createState() => _VideoSlimProgressBarState();
}

class _VideoSlimProgressBarState extends State<VideoSlimProgressBar> {
  Timer? _timer;
  double _fraction = 0;

  /// 比例变化小于这个量不重建：一条最宽也就一千多像素的线，千分之一的变化
  /// 连一个物理像素都不到，重建纯属浪费。
  static const double _minVisibleDelta = 0.001;

  @override
  void initState() {
    super.initState();
    _fraction = _readFraction();
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant VideoSlimProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshInterval != widget.refreshInterval) _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.refreshInterval, (_) => _tick());
  }

  double _readFraction() => videoSlimProgressFraction(
    positionMs: widget.positionMs(),
    durationMs: widget.durationMs(),
  );

  void _tick() {
    if (!mounted) return;
    final double next = _readFraction();
    if ((next - _fraction).abs() < _minVisibleDelta) return;
    setState(() => _fraction = next);
  }

  @override
  Widget build(BuildContext context) {
    final Color track =
        widget.trackColor ?? widget.color.withValues(alpha: 0.22);
    // 纯装饰层：不参与语义树，也不吃指针（挂载点另外包了 IgnorePointer，
    // 这里再声明一次是为了组件单独被复用时也不会挡住底下的控制条命中区）。
    return ExcludeSemantics(
      child: IgnorePointer(
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ColoredBox(color: track),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FractionallySizedBox(
                  widthFactor: _fraction,
                  heightFactor: 1,
                  child: ColoredBox(color: widget.color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
