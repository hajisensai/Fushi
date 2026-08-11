import 'dart:math' as math;

/// 移动端横滑 seek 的灵敏度档位（BUG-1485）。
///
/// 档位语义是「拖过**整屏宽度**跨越多长的视频时间」，与视频总时长**解耦**——这是
/// 与旧模型最本质的差别（旧模型按总时长比例换算，长视频一拽就起飞）。数值越小越钝。
enum VideoSeekSensitivity {
  /// 拖过整屏 ≈ 45 秒。逐句 / 逐镜头级微调。
  low(Duration(seconds: 45)),

  /// 拖过整屏 ≈ 90 秒。默认档。
  medium(Duration(seconds: 90)),

  /// 拖过整屏 ≈ 180 秒。偏向快速粗调，仍远钝于旧的比例制。
  high(Duration(seconds: 180));

  const VideoSeekSensitivity(this.fullWidthSpan);

  /// 拖过整屏宽度（且不触发时长相关钳制时）对应的基准跨度。
  final Duration fullWidthSpan;

  /// 持久化值（存 name 字符串，见 `PreferenceKeys.videoSeekSensitivity`）。
  /// 未知/损坏值回落 [medium]，不抛。
  static VideoSeekSensitivity fromName(String? name) {
    for (final VideoSeekSensitivity value in VideoSeekSensitivity.values) {
      if (value.name == name) return value;
    }
    return VideoSeekSensitivity.medium;
  }
}

/// 移动端视频横滑 seek 的像素→时间换算模型（BUG-1485）。
///
/// **旧模型（media_kit fork 内建，本类取代之）**：
/// `seconds = dragDx * duration / horizontalGestureSensitivity`（默认分母 1000）。
/// 即**每像素跨越的时间与视频总时长成正比**：2 小时的片子每像素 7.2 秒，手机屏宽
/// ~400dp 拖满全屏 = 48 分钟，轻轻一拽就起飞；反过来 3 分钟的短片又太钝。
///
/// **新模型**：灵敏度与总时长解耦。
///  1. 基准跨度由用户档位 [VideoSeekSensitivity.fullWidthSpan] 给出（「拖过整屏 = N 秒」）。
///  2. 对超长 / 超短视频做上下限钳制（[_resolveSpan]）：超长片给一个总时长比例地板，
///     免得 3 小时的片子只能一屏一屏挪；超短片给一个总时长比例天花板，免得一屏就飞过全片。
///  3. 叠加幂函数阻尼（[_dampingGamma] > 1）：小位移更细（可做秒级微调），大位移更快。
///     端点不变——拖满整屏仍恰好等于钳制后的跨度，阻尼只改变中间段的分布。
///
/// 全部是无依赖纯函数，便于直接单测（真实手势在 headless widget 测试里驱动不了，
/// 见 `test/media/video/video_horizontal_seek_gesture_test.dart`）。
class VideoHorizontalSeekGesture {
  const VideoHorizontalSeekGesture._();

  /// 阻尼指数。`shaped = norm^gamma`，gamma > 1 → 小位移被压得更小。
  /// 1.0 = 线性（无阻尼）。
  static const double _dampingGamma = 1.5;

  /// 跨度地板的总时长比例：跨度不小于 `duration * 0.03`。超长片（3 小时以上）才生效，
  /// 保证粗调仍可用（3 小时片 ≈ 5.4 分钟/屏）。
  static const double _spanFloorFraction = 0.03;

  /// 跨度地板的绝对下限：再短的片子，拖满整屏也至少能跨 15 秒（除非全片更短）。
  static const Duration _spanFloorAbsolute = Duration(seconds: 15);

  /// 跨度天花板的总时长比例：拖满整屏最多跨越全片的 50%，短片不会一屏飞完。
  static const double _spanCeilFraction = 0.5;

  /// 拖动位移 → 有符号时间增量。
  ///
  /// [dragDx] 是**相对拖动起点**的有符号水平位移（逻辑像素，右为正 = 快进）；
  /// [surfaceWidth] 是播放画面宽度（逻辑像素）；[position] 是拖动起点的播放位置。
  /// 返回值已保证 `position + delta` 落在 `[0, duration]` 内。
  ///
  /// 时长未知 / 非正（直播、尚未加载）或画面宽度非正时返回 [Duration.zero]（不 seek）。
  static Duration resolveDelta({
    required double dragDx,
    required double surfaceWidth,
    required Duration duration,
    required Duration position,
    required VideoSeekSensitivity sensitivity,
  }) {
    if (!dragDx.isFinite || !surfaceWidth.isFinite) return Duration.zero;
    if (surfaceWidth <= 0 || duration <= Duration.zero) return Duration.zero;

    final int spanMs = _resolveSpan(duration, sensitivity).inMilliseconds;
    if (spanMs <= 0) return Duration.zero;

    final double norm = (dragDx.abs() / surfaceWidth).clamp(0.0, 1.0);
    final double shaped = math.pow(norm, _dampingGamma).toDouble();
    final int magnitudeMs = (spanMs * shaped).round();
    final int deltaMs = dragDx.isNegative ? -magnitudeMs : magnitudeMs;

    // clamp 到可达区间：向前不越过片尾，向后不越过片头。
    final int positionMs =
        position.inMilliseconds.clamp(0, duration.inMilliseconds);
    final int targetMs =
        (positionMs + deltaMs).clamp(0, duration.inMilliseconds);
    return Duration(milliseconds: targetMs - positionMs);
  }

  /// 拖动位移 → 目标绝对播放位置（已 clamp 到 `[0, duration]`）。
  /// 参数语义同 [resolveDelta]。
  static Duration resolveTarget({
    required double dragDx,
    required double surfaceWidth,
    required Duration duration,
    required Duration position,
    required VideoSeekSensitivity sensitivity,
  }) {
    final Duration delta = resolveDelta(
      dragDx: dragDx,
      surfaceWidth: surfaceWidth,
      duration: duration,
      position: position,
      sensitivity: sensitivity,
    );
    final int positionMs =
        position.inMilliseconds.clamp(0, duration.inMilliseconds);
    return Duration(milliseconds: positionMs + delta.inMilliseconds);
  }

  /// 「拖过整屏 = 多长」的实际跨度：档位基准值经超长 / 超短片钳制。
  ///
  /// 地板 = `min(max(15s, duration * 3%), duration)`；天花板 = `max(地板, duration * 50%)`。
  /// 地板先被总时长兜住，保证极短片（比 15 秒还短）不会出现「地板 > 全片」的反直觉档。
  static Duration _resolveSpan(
    Duration duration,
    VideoSeekSensitivity sensitivity,
  ) {
    final int durationMs = duration.inMilliseconds;
    final int floorMs = math.min(
      math.max(
        _spanFloorAbsolute.inMilliseconds,
        (durationMs * _spanFloorFraction).round(),
      ),
      durationMs,
    );
    final int ceilMs = math.max(
      floorMs,
      (durationMs * _spanCeilFraction).round(),
    );
    final int baseMs = sensitivity.fullWidthSpan.inMilliseconds;
    return Duration(milliseconds: baseMs.clamp(floorMs, ceilMs));
  }
}
