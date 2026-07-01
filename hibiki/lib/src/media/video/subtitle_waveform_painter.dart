import 'package:flutter/widgets.dart';

/// 字幕对轴的音频波形可视化 painter（TODO-1051 阶段B）。
///
/// 消费 `audio_energy_probe.dart` 的 `downsampleEnergyEnvelope` 输出（归一化 0..1 的
/// 波形桶，覆盖一段固定时间窗 `[windowStartMs, windowEndMs)`），画三层：
/// 1. **波形柱**：每个桶一根从中线上下对称展开的柱，高度 = 桶值 × 可用半高。
/// 2. **字幕 cue 边界标线**：每条 cue 的 start/end 时间**加上预览延迟 [previewDelayMs]**
///    后映射到 x，画竖线——用户拖延迟时这些线整体平移，直观看出「字幕往哪挪、挪多少」。
/// 3. **当前对轴位置指示**：把 [currentPositionMs] 映射到 x 画一条高亮竖线（播放头）。
///
/// 几何（桶→x、时间→x）抽成**纯顶层函数**（[waveformBucketRect] / [timeToX]），无
/// BuildContext / Canvas 依赖，可单测。颜色全部由构造参数注入（页面/面板从 MD3
/// `ColorScheme` 派生后传入），本文件不硬编码任何颜色，避免撞 md3 守卫。

/// **纯函数**：把第 [bucketIndex] 个波形桶（共 [bucketCount] 个，值 [value]∈0..1）
/// 映射成一根上下对称的柱 [Rect]。
///
/// 柱在 `[0, size.width)` 上按桶数均分，第 i 桶占 `[i*w/N, (i+1)*w/N)`；柱宽取该格宽
/// 减 [gap]（两侧留白，clamp 到 >=1 逻辑像素避免消失）。柱高 = `value × (半高 - 垂直
/// 内边距)`，以中线 [centerY] 为轴上下对称展开。空/非法输入（桶数<=0、宽/高<=0）返回
/// `Rect.zero`（调用方跳过绘制）。
///
/// 无 IO、无 Canvas 依赖，幂等可单测。
Rect waveformBucketRect({
  required int bucketIndex,
  required int bucketCount,
  required double value,
  required Size size,
  required double centerY,
  double gap = 1.0,
  double verticalPadding = 0.0,
}) {
  if (bucketCount <= 0 || size.width <= 0 || size.height <= 0) {
    return Rect.zero;
  }
  if (bucketIndex < 0 || bucketIndex >= bucketCount) return Rect.zero;
  final double slot = size.width / bucketCount;
  final double left = bucketIndex * slot;
  // 柱宽 = 格宽 - gap，clamp 到 [1, slot]（gap 过大也不至于宽度为负/零）。
  final double barWidth = (slot - gap).clamp(1.0, slot);
  // 柱居中在格内（左右各留 (slot - barWidth)/2）。
  final double barLeft = left + (slot - barWidth) / 2;
  final double clampedValue = value.clamp(0.0, 1.0).toDouble();
  final double halfSpan =
      (size.height / 2 - verticalPadding).clamp(0.0, size.height / 2);
  final double halfHeight = clampedValue * halfSpan;
  return Rect.fromLTRB(
    barLeft,
    centerY - halfHeight,
    barLeft + barWidth,
    centerY + halfHeight,
  );
}

/// **纯函数**：把时间 [timeMs] 映射到时间窗 `[windowStartMs, windowEndMs)` 上的 x 像素。
///
/// 线性映射 `(timeMs - start) / (end - start) × width`。窗口退化（end<=start）或非正
/// 宽度返回 `double.nan`（调用方据 `isNaN` 跳过绘制，不画到窗外）。**不 clamp**：落在
/// 窗外的时间返回窗外 x，由调用方按 `[0, width]` 裁剪决定画不画（cue 边界线只在窗内可见）。
double timeToX({
  required int timeMs,
  required int windowStartMs,
  required int windowEndMs,
  required double width,
}) {
  final int span = windowEndMs - windowStartMs;
  if (span <= 0 || width <= 0) return double.nan;
  return (timeMs - windowStartMs) / span * width;
}

/// 字幕对轴波形 painter（TODO-1051 阶段B）。纯绘制，几何走上面的纯函数。
class SubtitleWaveformPainter extends CustomPainter {
  SubtitleWaveformPainter({
    required this.buckets,
    required this.windowStartMs,
    required this.windowEndMs,
    required this.cueBoundariesMs,
    required this.previewDelayMs,
    required this.currentPositionMs,
    required this.waveColor,
    required this.cueLineColor,
    required this.playheadColor,
    required this.centerLineColor,
    this.gap = 1.0,
    this.verticalPadding = 4.0,
    this.cueLineWidth = 1.5,
    this.playheadWidth = 2.0,
  });

  /// 归一化 0..1 波形桶（`downsampleEnergyEnvelope` 输出），覆盖时间窗
  /// `[windowStartMs, windowEndMs)`。空 → 只画中线 + cue 边界 + 播放头（降级）。
  final List<double> buckets;

  /// 波形时间窗起点（毫秒，含）。
  final int windowStartMs;

  /// 波形时间窗终点（毫秒，不含）。
  final int windowEndMs;

  /// 字幕 cue 的时间边界（毫秒，未加延迟的原始 start/end 混合列表）。painter 内部
  /// **加上** [previewDelayMs] 后映射。cue.startMs/endMs 不可变——延迟只在可视化时叠加。
  final List<int> cueBoundariesMs;

  /// 当前预览的字幕延迟（毫秒，正=字幕延后）。拖动时实时变，cue 边界线随之整体平移。
  final int previewDelayMs;

  /// 当前播放位置（毫秒），画播放头竖线。
  final int currentPositionMs;

  /// 波形柱颜色。
  final Color waveColor;

  /// cue 边界竖线颜色。
  final Color cueLineColor;

  /// 播放头竖线颜色。
  final Color playheadColor;

  /// 水平中线颜色。
  final Color centerLineColor;

  /// 柱间留白（逻辑像素）。
  final double gap;

  /// 波形上下垂直内边距（逻辑像素）。
  final double verticalPadding;

  /// cue 边界线宽（逻辑像素）。
  final double cueLineWidth;

  /// 播放头线宽（逻辑像素）。
  final double playheadWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final double centerY = size.height / 2;

    // 1. 水平中线（波形轴，即便无波形也画出「有一条轴」的空态）。
    final Paint centerPaint = Paint()
      ..color = centerLineColor
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      centerPaint,
    );

    // 2. 波形柱（有桶才画；空桶 = 移动端降级，只留中线/cue/播放头）。
    if (buckets.isNotEmpty) {
      final Paint wavePaint = Paint()..color = waveColor;
      final int n = buckets.length;
      for (int i = 0; i < n; i++) {
        final Rect bar = waveformBucketRect(
          bucketIndex: i,
          bucketCount: n,
          value: buckets[i],
          size: size,
          centerY: centerY,
          gap: gap,
          verticalPadding: verticalPadding,
        );
        if (bar == Rect.zero || bar.height <= 0) continue;
        canvas.drawRect(bar, wavePaint);
      }
    }

    // 3. cue 边界竖线（加预览延迟后映射；只画落在窗内的）。
    final Paint cuePaint = Paint()
      ..color = cueLineColor
      ..strokeWidth = cueLineWidth;
    for (final int boundaryMs in cueBoundariesMs) {
      final double x = timeToX(
        timeMs: boundaryMs + previewDelayMs,
        windowStartMs: windowStartMs,
        windowEndMs: windowEndMs,
        width: size.width,
      );
      if (x.isNaN || x < 0 || x > size.width) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), cuePaint);
    }

    // 4. 当前播放位置指示（播放头）。
    final double playheadX = timeToX(
      timeMs: currentPositionMs,
      windowStartMs: windowStartMs,
      windowEndMs: windowEndMs,
      width: size.width,
    );
    if (!playheadX.isNaN && playheadX >= 0 && playheadX <= size.width) {
      final Paint playheadPaint = Paint()
        ..color = playheadColor
        ..strokeWidth = playheadWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(playheadX, 0),
        Offset(playheadX, size.height),
        playheadPaint,
      );
    }
  }

  @override
  bool shouldRepaint(SubtitleWaveformPainter old) =>
      old.previewDelayMs != previewDelayMs ||
      old.currentPositionMs != currentPositionMs ||
      old.windowStartMs != windowStartMs ||
      old.windowEndMs != windowEndMs ||
      old.waveColor != waveColor ||
      old.cueLineColor != cueLineColor ||
      old.playheadColor != playheadColor ||
      old.centerLineColor != centerLineColor ||
      old.gap != gap ||
      old.verticalPadding != verticalPadding ||
      old.cueLineWidth != cueLineWidth ||
      old.playheadWidth != playheadWidth ||
      !_sameList(old.buckets, buckets) ||
      !_sameIntList(old.cueBoundariesMs, cueBoundariesMs);

  static bool _sameList(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameIntList(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
