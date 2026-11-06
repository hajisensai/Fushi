/// 字幕调轴滑条的可拖范围（反馈 pHsnXu5YSg / ylzYBx1FmW）。
///
/// 旧实现把滑条钉死在 ±10 s：在线源插了一段十几秒的片尾曲时，拖到端点也对不上，
/// 用户不知道还能点读数键入。现在滑条范围按 [kSubtitleDelaySliderStepMs] 一档
/// 「随当前值扩展」：基础 ±30 s；当前值触到（或越过）端点时，范围扩成下一个
/// 30 s 的整数倍——拖到 +30 s 松手，滑条就变成 ±60 s，可以继续往外拖。
/// 小偏移时范围不变宽，滑条精度不受影响；更精细的调节仍走 ±50 ms / ±1000 ms
/// 步进钮和可键入的读数。上界与 VideoPlayerController 的 clamp（±600 s）一致。
library;

/// 扩展步长 / 基础范围（毫秒）。
const int kSubtitleDelaySliderStepMs = 30000;

/// 调轴绝对上界（毫秒），与 VideoPlayerController.setDelayMs 的 clamp 一致。
const int kSubtitleDelayClampMs = 600000;

/// 当前延迟 [delayMs] 下滑条的半宽（毫秒）：至少 [kSubtitleDelaySliderStepMs]，
/// |delayMs| 触到端点时扩到能把它放进内部的下一个整档，封顶 [kSubtitleDelayClampMs]。
int subtitleDelaySliderRangeMs(int delayMs) {
  final int magnitude = delayMs.abs();
  final int steps = magnitude ~/ kSubtitleDelaySliderStepMs + 1;
  final int range = steps * kSubtitleDelaySliderStepMs;
  return range > kSubtitleDelayClampMs ? kSubtitleDelayClampMs : range;
}

/// 滑条分档数：每档 50 ms 太密（±600 s 时 24000 档），按范围取 50 ms 或 100 ms 一档，
/// 精细调节交给步进钮与读数输入。
int subtitleDelaySliderDivisions(int rangeMs) {
  final int stepMs = rangeMs <= kSubtitleDelaySliderStepMs ? 50 : 100;
  return (rangeMs * 2) ~/ stepMs;
}
