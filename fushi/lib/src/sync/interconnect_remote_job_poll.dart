// 互联远端任务（通用任务 `/api/jobs`、漫画 OCR `/api/ocr/job`）的 client 侧共享观测原语。
//
// 两个 client 以前各自算退避：漫画 OCR 的 `mangaOcrPollDelay` 先 `pow` 再 `round` 再封顶，
// attempt≈1736 时 `pow` 得 Infinity，`Infinity.round()` 抛 UnsupportedError（BUG：
// remote-job-poll-delay-overflow）；通用任务 client 复用它，长任务约 2.4 小时后必然自删。

import 'dart:math';

/// 远端任务轮询退避：500ms 起 ×1.5，封顶 5s。指数先夹到封顶所需的最小值再算，
/// 任意 attempt（含 int 上界）都不会产生 Infinity / NaN。
Duration remoteJobPollDelay(int attempt) {
  const int baseMs = 500;
  const int maxMs = 5000;
  const int capExponent = 6; // 500 × 1.5^6 = 5695 > 5000
  final int e = attempt <= 0
      ? 0
      : (attempt >= capExponent ? capExponent : attempt);
  return Duration(milliseconds: min((baseMs * pow(1.5, e)).round(), maxMs));
}
