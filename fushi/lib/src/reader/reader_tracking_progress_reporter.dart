/// 阅读器 → 追踪服务的进度上报口（BUG-4807）。
///
/// 上报要查库、可能内联一次站点搜索（未映射的书第一次上报）和一次条目读取，
/// 耗时没有上界。它不属于「位置落库」：阅读器的返回键等着位置落库，却不该等它。
/// 所以这里只**发起**上报，不让调用方等：
///
/// - 同一份进度（完成章数 + 是否读完）**落定**之后不再上报。位置落库每 500 ms
///   防抖一次、每翻一页都来，章内翻页时这两个值不变，没有新东西可报。
/// - 「落定」由服务说了算（[ReaderTrackingProgressSend] 的返回值），不是「调用正常
///   返回」：服务把站点搜索的网络失败、搜索未命中、入队失败都吞成正常返回。没落定
///   的进度不记成已报，下一次落库照常再调服务（搜索频率由服务自己的未命中窗限制）。
/// - 同一份进度的上报还在途时不重复发起。
/// - 抛错记日志，同样不算已报。
/// - 进程退出要把在途的上报等完，用 [whenSettled]。
///
/// 纯 Dart，不依赖 Flutter / 追踪服务本身，可单测。
library;

import 'dart:async';

/// 一次上报的失败回调（记日志用）。
typedef ReaderTrackingProgressErrorHandler =
    void Function(Object error, StackTrace stack);

/// 发起一次上报。完成值 = 这份进度是否已**落定**（进了站点队列，且没有还在等
/// 映射的站点）；`false` = 没落定，下次落库要再报。
typedef ReaderTrackingProgressSend = Future<bool> Function();

class ReaderTrackingProgressReporter {
  ReaderTrackingProgressReporter({required this.onError});

  final ReaderTrackingProgressErrorHandler onError;

  /// 最近一次发起、且在途或已落定的进度；`null` = 没有（没报过，或上一次没落定）。
  ({int completedChapterCount, bool completed})? _lastReported;

  final Set<Future<void>> _inFlight = <Future<void>>{};

  /// 进度与 [_lastReported] 不同就调 [send] 发起一次上报，返回是否发起。
  ///
  /// [send] 的 Future 不交还给调用方：它在后台跑完，抛错走 [onError]。
  bool report({
    required int completedChapterCount,
    required bool completed,
    required ReaderTrackingProgressSend send,
  }) {
    final ({int completedChapterCount, bool completed}) next = (
      completedChapterCount: completedChapterCount,
      completed: completed,
    );
    if (_lastReported == next) return false;
    _lastReported = next;
    // 这份进度没落定：忘掉它，下一次落库再报。期间已经发起了更新的进度就不动
    // ——那一份自己负责自己。
    void forget() {
      if (_lastReported == next) _lastReported = null;
    }

    late final Future<void> run;
    run = Future<bool>.sync(send)
        .then<void>(
          (bool settled) {
            if (!settled) forget();
          },
          onError: (Object error, StackTrace stack) {
            forget();
            onError(error, stack);
          },
        )
        .whenComplete(() => _inFlight.remove(run));
    _inFlight.add(run);
    return true;
  }

  /// 在途的上报全部结束（落定、没落定或抛错）后完成；不抛错。
  Future<void> whenSettled() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
  }
}
