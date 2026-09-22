import 'dart:async';
import 'dart:math' as math;

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

/// 细进度条上一次点击 / 拖动落在哪个进度比例（`0..1`）。纯函数，组件与测试同源。
///
/// 与 media_kit fork 那条常规进度条同口径（`material_desktop.dart` 的
/// `e.localPosition.dx / constraints.maxWidth`）：细线**没有**横向 margin
/// （挂载点是 `Positioned(left: 0, right: 0)`），所以分母直接就是自身宽度，
/// 不需要像章节刻度层那样再减 `seekBarMargin`。
///
/// 宽度非有限或 <= 0（首帧前 constraints 还没落定）返回 null =「这次交互不产生
/// seek」，而不是返回 0 —— 后者会把首帧的一次误触变成「跳回片头」。
double? videoSlimProgressSeekFraction({
  required double dx,
  required double width,
}) {
  if (!width.isFinite || width <= 0 || !dx.isFinite) return null;
  return (dx / width).clamp(0.0, 1.0);
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
    this.onSeekFraction,
    this.hitTestHeight = 12,
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

  /// 点击 / 横拖这条线时的跳转回调，参数是落点的进度比例（`0..1`）。
  ///
  /// null = 纯装饰（组件退回 [IgnorePointer] 形态，逐像素与加手势前一致）。调用方
  /// 按「此刻该不该让它吃指针」决定传不传：沉浸锁 / 侧面板 / 控件编辑态下必须传
  /// null，否则细线会成为那几个门控唯一漏掉的可点区（它挂在 media_kit 控制条那层
  /// [IgnorePointer] 之外）。
  final ValueChanged<double>? onSeekFraction;

  /// 命中带高度（逻辑像素），仅 [onSeekFraction] 非 null 时生效。
  ///
  /// 与可见线高 [height] 分离：3 像素的线鼠标都难瞄准、触屏更不可能，所以向上
  /// 补一段**透明**命中带。不取更高是因为这条带压在画面最底边，越高越容易把本该
  /// 落到画面的单击（点画面暂停）吃掉；12 逻辑像素约等于一根手指的一半，实测
  /// 既能瞄准又不至于误触。
  final double hitTestHeight;

  @override
  State<VideoSlimProgressBar> createState() => _VideoSlimProgressBarState();
}

class _VideoSlimProgressBarState extends State<VideoSlimProgressBar> {
  Timer? _timer;
  double _fraction = 0;

  /// 比例变化小于这个量不重建：一条最宽也就一千多像素的线，千分之一的变化
  /// 连一个物理像素都不到，重建纯属浪费。
  static const double _minVisibleDelta = 0.001;

  /// 自己发起 seek 后的「静默窗」：这段时间内轮询读回的位置不许覆盖乐观值。
  ///
  /// 播放器的 position 要等 seek 真落地才更新（网络流上尤其慢），不静默的话
  /// 用户松手后那条线会先弹回原处、再跳到目标，看着像点歪了。
  static const Duration _seekSettleWindow = Duration(milliseconds: 500);

  /// 横拖过程中 seek 的最小间隔：每帧都提交会让播放器被 seek 请求淹没
  /// （每次 `seekMs` 还要重建字幕权威），拖完的终值另由 drag end 补发。
  static const Duration _dragSeekThrottle = Duration(milliseconds: 100);

  DateTime? _seekSettleUntil;
  DateTime? _lastSeekSentAt;
  double? _pendingDragFraction;

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
    final DateTime? settleUntil = _seekSettleUntil;
    if (settleUntil != null) {
      if (DateTime.now().isBefore(settleUntil)) return;
      _seekSettleUntil = null;
    }
    final double next = _readFraction();
    if ((next - _fraction).abs() < _minVisibleDelta) return;
    setState(() => _fraction = next);
  }

  /// 把一次落点变成「线立即到位 + 回调发出」。[throttled] 为真时（横拖途中）
  /// 只保证线跟手，回调按 [_dragSeekThrottle] 限频。
  void _seekAt(double dx, double width, {bool throttled = false}) {
    final ValueChanged<double>? onSeek = widget.onSeekFraction;
    if (onSeek == null) return;
    final double? fraction = videoSlimProgressSeekFraction(
      dx: dx,
      width: width,
    );
    if (fraction == null) return;
    _seekSettleUntil = DateTime.now().add(_seekSettleWindow);
    if (fraction != _fraction) setState(() => _fraction = fraction);
    if (throttled) {
      _pendingDragFraction = fraction;
      final DateTime? last = _lastSeekSentAt;
      if (last != null && DateTime.now().difference(last) < _dragSeekThrottle) {
        return;
      }
    }
    _lastSeekSentAt = DateTime.now();
    onSeek(fraction);
  }

  /// 松手：限频可能把最后一次落点吞掉，终值必须无条件补发一次，否则线停在
  /// 手指处、播放位置却停在上一次被放行的采样点。
  void _commitDragSeek() {
    final double? pending = _pendingDragFraction;
    _pendingDragFraction = null;
    _lastSeekSentAt = null;
    if (pending == null) return;
    widget.onSeekFraction?.call(pending);
  }

  @override
  Widget build(BuildContext context) {
    final Color track =
        widget.trackColor ?? widget.color.withValues(alpha: 0.22);
    // 纯装饰层：不参与语义树，也不吃指针（下面那层命中带是唯一吃指针的地方；
    // 这里再声明一次是为了组件单独被复用时也不会挡住底下的控制条命中区）。
    final Widget line = ExcludeSemantics(
      child: IgnorePointer(
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ColoredBox(color: track),
              Align(
                // 物理左端，不随 TextDirection 镜像：点击换算 `dx / width` 是从左算
                // 的，media_kit 的进度条也是硬 ltr——RTL 界面下填充从右长、点击却
                // 从左算，点在可见填充端点处会跳到镜像位置（PR #1600 审查）。
                alignment: Alignment.centerLeft,
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
    if (widget.onSeekFraction == null) return line;
    // 可交互形态：可见线贴底、上方补一段透明命中带。命中带用 `opaque` 吃掉这次
    // 指针，media_kit 控制条那层的「点画面暂停」因此收不到——正是想要的：点这条
    // 线只跳转，不顺手把播放态也翻了。页面最外层那条 translucent Listener 仍会
    // 收到 pointer-up，但它的 [_isVideoChromePointer] 早把底部整条带判为 chrome、
    // 不会触发双击全屏。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        return SizedBox(
          height: math.max(widget.hitTestHeight, widget.height),
          width: double.infinity,
          child: Stack(
            children: <Widget>[
              Positioned(left: 0, right: 0, bottom: 0, child: line),
              Positioned.fill(
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (TapDownDetails d) =>
                        _seekAt(d.localPosition.dx, width),
                    onHorizontalDragStart: (DragStartDetails d) =>
                        _seekAt(d.localPosition.dx, width, throttled: true),
                    onHorizontalDragUpdate: (DragUpdateDetails d) =>
                        _seekAt(d.localPosition.dx, width, throttled: true),
                    onHorizontalDragEnd: (DragEndDetails _) =>
                        _commitDragSeek(),
                    onHorizontalDragCancel: _commitDragSeek,
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
