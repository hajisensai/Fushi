/// 在线 TTS 的临时失败退避重试（全部引擎共用的唯一一处）。
///
/// 为什么允许重试（不是掩盖）：在线语音（Edge / Azure / Google / 翻译朗读）跑在
/// 第三方服务与用户网络上，单句请求偶发的连接重置、超时、429 限流、5xx 与服务端
/// 提前断开是外部系统的常态，本机代码无法消除。一本书朗读要连续发几千个请求，
/// 零重试意味着任一次抖动都让朗读停下（用户报告「微软、谷歌的语音经常会断」）。
///
/// 约束（影响范围）：
/// - 只重试 [TtsFailure.isTransient] 判定为临时的失败；鉴权、参数 / 文本被拒、
///   语言不支持、未配置、坏响应一律立刻上报，不重试。
/// - 次数有上限（默认 3 次），用尽后把**最后一次的真实失败**原样抛出，调用方照旧
///   提示用户——失败不会被吞掉，也不会跳过句子。
/// - 退避等待可被 [TtsCancelToken] 立即中断（换位置 / 关闭朗读不会被退避拖住）。
/// - 服务端给了 `Retry-After` 就按它等（上限 [TtsRetryPolicy.maxRetryAfter]，
///   超过上限说明服务端要求长时间冷却，直接上报而不是让播放器缓冲几分钟）。
///
/// 清理条件：若某个引擎改成自带可靠重试 / 长连接复用，该引擎仍走这里不会出错
/// （它不再抛临时失败）；不需要为单个引擎另写重试。
library;

import 'dart:async';
import 'dart:math';

import 'package:fushi_engine/tts/tts_types.dart';

class TtsRetryPolicy {
  const TtsRetryPolicy({
    this.maxRetries = 3,
    this.baseDelay = const Duration(milliseconds: 600),
    this.maxDelay = const Duration(seconds: 8),
    this.maxRetryAfter = const Duration(seconds: 30),
  });

  /// 不重试（只发一次）。
  static const TtsRetryPolicy none = TtsRetryPolicy(maxRetries: 0);

  /// 第一次失败后最多再试几次。
  final int maxRetries;

  /// 第 n 次重试前的基准等待 = `baseDelay * 2^(n-1)`，封顶 [maxDelay]。
  final Duration baseDelay;
  final Duration maxDelay;

  /// 服务端 `Retry-After` 能接受的最长等待。
  final Duration maxRetryAfter;

  /// 第 [retry] 次重试（从 1 起）前等多久；null = 不再重试。
  ///
  /// 抖动取「基准的一半 .. 基准」之间均匀分布（equal jitter）：并发两路同时失败时
  /// 不会同一瞬间一起重打服务端，又保证至少等基准的一半。
  Duration? delayBefore(int retry, TtsFailure failure, Random random) {
    if (retry > maxRetries) return null;
    final Duration? retryAfter = failure.retryAfter;
    if (retryAfter != null) {
      if (retryAfter > maxRetryAfter) return null;
      return retryAfter.isNegative ? Duration.zero : retryAfter;
    }
    final int base = min(
      baseDelay.inMicroseconds * (1 << (retry - 1).clamp(0, 20)),
      maxDelay.inMicroseconds,
    );
    if (base <= 0) return Duration.zero;
    final int half = base ~/ 2;
    return Duration(microseconds: half + random.nextInt(base - half + 1));
  }
}

/// 执行 [attempt]；遇到临时失败按 [policy] 退避后重来。
///
/// - [cancel] 已取消（等待前或等待中）→ 抛 [TtsFailureCode.cancelled]。
/// - 非 [TtsFailure] 的异常不重试，原样抛出。
/// - [onRetry] 在每次决定重试、开始等待前调用（日志 / 测试观察用）。
Future<T> ttsWithRetry<T>(
  Future<T> Function() attempt, {
  required TtsCancelToken cancel,
  TtsRetryPolicy policy = const TtsRetryPolicy(),
  Random? random,
  void Function(int retry, TtsFailure failure, Duration delay)? onRetry,
}) async {
  final Random rng = random ?? Random();
  int retry = 0;
  while (true) {
    cancel.throwIfCancelled();
    try {
      return await attempt();
    } on TtsFailure catch (failure) {
      if (failure.code == TtsFailureCode.cancelled || cancel.isCancelled) {
        throw const TtsFailure(TtsFailureCode.cancelled);
      }
      if (!failure.isTransient) rethrow;
      retry++;
      final Duration? delay = policy.delayBefore(retry, failure, rng);
      if (delay == null) rethrow;
      onRetry?.call(retry, failure, delay);
      await _cancellableDelay(delay, cancel);
    }
  }
}

Future<void> _cancellableDelay(Duration delay, TtsCancelToken cancel) {
  cancel.throwIfCancelled();
  if (delay <= Duration.zero) return Future<void>.value();
  final Completer<void> done = Completer<void>();
  late final void Function() unregister;
  final Timer timer = Timer(delay, () {
    unregister();
    if (!done.isCompleted) done.complete();
  });
  unregister = cancel.onCancel(() {
    timer.cancel();
    if (!done.isCompleted) {
      done.completeError(const TtsFailure(TtsFailureCode.cancelled));
    }
  });
  return done.future;
}
