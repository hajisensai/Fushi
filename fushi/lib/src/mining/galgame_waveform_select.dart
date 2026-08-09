import 'dart:math' as math;

/// galgame 一键制卡（docs/specs/galgame-mining）波形选区纯逻辑。
///
/// 像素 ↔ 毫秒映射 + VAD 默认框，全部是无 Flutter 依赖的纯函数，供
/// `galgame_waveform_select_dialog.dart` 消费并可直接单测。

/// 一段音频里用户选中的时间范围（毫秒，start<=end，均 clamp 到 [0,totalMs]）。
class GalWaveformRange {
  const GalWaveformRange({required this.startMs, required this.endMs});

  final int startMs;
  final int endMs;

  int get durationMs => endMs - startMs;

  @override
  String toString() => 'GalWaveformRange($startMs..$endMs)';
}

/// 像素 x（0..width）反算成毫秒（线性映射到 [0,totalDurationMs]），clamp 到
/// [0,total]。width<=0 或 total<=0 返回 0。
int pixelToMs(double x, double width, int totalDurationMs) {
  if (width <= 0 || totalDurationMs <= 0) {
    return 0;
  }
  final int ms = (x / width * totalDurationMs).round();
  return ms.clamp(0, totalDurationMs);
}

/// 毫秒映射回像素 x（[pixelToMs] 的逆）。total<=0 或 width<=0 返回 0。
double msToPixel(int ms, double width, int totalDurationMs) {
  if (totalDurationMs <= 0 || width <= 0) {
    return 0;
  }
  final int clamped = ms.clamp(0, totalDurationMs);
  return clamped / totalDurationMs * width;
}

/// VAD 默认框：在逐帧 dBFS 包络 [dbFrames]（每帧覆盖 [windowMs] 毫秒，帧值 ∈
/// [-120,0]）上，取阈值 = max(峰值 - [relDropDb], [absFloorDb])，找**最后一段**
/// 连续高于阈值的帧区间，换算成毫秒 [GalWaveformRange]（galgame 一句语音通常是
/// 缓冲尾部最近一段）。
///
/// 无任何帧高于阈值 / [dbFrames] 空 → 返回覆盖全段的 range（fail-open：整段
/// 可选，用户再手拖）。[totalDurationMs] 用于末段 clamp（最后一帧右界不超过
/// total）。
GalWaveformRange defaultVadRange(
  List<double> dbFrames, {
  required int windowMs,
  required int totalDurationMs,
  double relDropDb = 20.0,
  double absFloorDb = -40.0,
}) {
  final int total = math.max(0, totalDurationMs);
  final GalWaveformRange fullRange = GalWaveformRange(startMs: 0, endMs: total);
  if (dbFrames.isEmpty || windowMs <= 0) {
    return fullRange;
  }

  // 阈值 = max(峰值 - relDropDb, absFloorDb)。
  double peak = dbFrames[0];
  for (final double db in dbFrames) {
    if (db > peak) peak = db;
  }
  final double threshold = math.max(peak - relDropDb, absFloorDb);

  // 从后往前找最后一个 >= 阈值的帧；没有任何帧过阈值 → fail-open 全段。
  int lastIdx = -1;
  for (int i = dbFrames.length - 1; i >= 0; i--) {
    if (dbFrames[i] >= threshold) {
      lastIdx = i;
      break;
    }
  }
  if (lastIdx < 0) {
    return fullRange;
  }

  // 从 lastIdx 向前延伸，遇到 < 阈值处停，得到最后一段响区 [firstIdx,lastIdx]。
  int firstIdx = lastIdx;
  while (firstIdx > 0 && dbFrames[firstIdx - 1] >= threshold) {
    firstIdx--;
  }

  final int startMs = (firstIdx * windowMs).clamp(0, total);
  final int endMs = math.min(total, (lastIdx + 1) * windowMs);
  if (endMs <= startMs) {
    return fullRange;
  }
  return GalWaveformRange(startMs: startMs, endMs: endMs);
}
