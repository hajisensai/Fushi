/// 有声书「跳转回退」阈值：一次显式音频 seek 要把全书位置挪动多远，才把出发点压进
/// 阅读器的「← 返回 / 前进 →」历史（[AudiobookPlayerController.onBeforeAudioJump]）。
///
/// 反馈 0AwuVqrNFn：旧阈值写死 15 秒，没听清往回拖一分钟、回翻两页都会弹出返回胶囊。
/// 所有者 2026-10-27 批准：默认 2 分钟，并在「阅读 › 有声书」设置里可改（15 秒–30 分钟）。
/// 值域收成一组档位而不是任意秒数：设置行是下拉单选，档位外的存值（手改库 / 旧版本）
/// 按 [normalizeAudiobookJumpThresholdSec] 归到最近档位，读写两侧同一判据。
library;

/// 出厂默认（秒）。
const int kAudiobookJumpThresholdSecDefault = 120;

/// 合理区间下限（秒）：低于它逐句、几秒的修正也会进历史。
const int kAudiobookJumpThresholdSecMin = 15;

/// 合理区间上限（秒）。
const int kAudiobookJumpThresholdSecMax = 1800;

/// 设置下拉里提供的档位（秒，升序，含默认值）。
const List<int> kAudiobookJumpThresholdSecChoices = <int>[
  15,
  30,
  60,
  120,
  300,
  600,
  900,
  1800,
];

/// 把任意存值归到最近的档位（[kAudiobookJumpThresholdSecChoices]，自然落在
/// [kAudiobookJumpThresholdSecMin]..[kAudiobookJumpThresholdSecMax] 内）：下拉只认
/// 档位值，档位外的存值不能让设置行选不中任何一项。等距时取较大的一档。
int normalizeAudiobookJumpThresholdSec(num value) {
  final int sec = value.round();
  int best = kAudiobookJumpThresholdSecChoices.first;
  for (final int choice in kAudiobookJumpThresholdSecChoices) {
    if ((choice - sec).abs() <= (best - sec).abs()) best = choice;
  }
  return best;
}
