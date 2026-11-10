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

/// 观测链路判定为断连前的容忍窗：从第一次观测失败起算。
const Duration kRemoteJobLinkLossTolerance = Duration(minutes: 10);

/// 远端任务的观测链路状态：观测失败（传输层看不到 host）≠ 任务失败（host 判定）。
///
/// host 上的任务状态才是真相源。一次 GET 因超时 / 断网落空只说明「此刻看不到」，
/// 进入断连子状态继续观测；从**第一次失败的时刻**起超过 [tolerance] 仍看不到才判定
/// 断连（移动端被挂起几十分钟后回到前台，第一次失败才开始计时）。任意一次观测成功
/// 立即退出断连子状态、计时清零。
class RemoteJobLinkWatch {
  RemoteJobLinkWatch({required Duration tolerance, DateTime Function()? now})
    : _tolerance = tolerance,
      _now = now ?? DateTime.now;

  final Duration _tolerance;
  final DateTime Function() _now;
  DateTime? _lostSince;

  /// 一次观测成功：退出断连子状态。
  void observed() => _lostSince = null;

  /// 一次观测因传输失败落空。返回 true = 仍在容忍窗内（继续观测）；false = 判定断连。
  bool lost() {
    final DateTime now = _now();
    final DateTime since = _lostSince ??= now;
    return now.difference(since) <= _tolerance;
  }

  /// 当前是否处在断连子状态（最近一次观测失败、之后还没成功过）。
  bool get isLost => _lostSince != null;

  /// 断连子状态的起点（第一次失败的时刻）；不在断连中为 null。
  DateTime? get lostSince => _lostSince;
}
