/// 阅读器 → 追踪服务的进度上报口（BUG-4791）。
///
/// 上报要查库、可能内联一次站点搜索（未映射的书第一次上报）和一次条目读取，
/// 耗时没有上界。它不属于「位置落库」：阅读器的返回键等着位置落库，却不该等它。
/// 所以这里只**发起**上报，不让调用方等：
///
/// - 同一份进度（完成章数 + 是否读完）只上报一次。位置落库每 500 ms 防抖一次、
///   每翻一页都来，章内翻页时这两个值不变，没有新东西可报。
/// - 失败记日志并忘掉这份进度，下一次落库照常再报——上报失败不该让这本书在本次
///   阅读里再也不报。
/// - 进程退出要把在途的上报等完，用 [whenSettled]。
///
/// 纯 Dart，不依赖 Flutter / 追踪服务本身，可单测。
library;

import 'dart:async';

/// 一次上报的失败回调（记日志用）。
typedef ReaderTrackingProgressErrorHandler =
    void Function(Object error, StackTrace stack);

class ReaderTrackingProgressReporter {
  ReaderTrackingProgressReporter({required this.onError});

  final ReaderTrackingProgressErrorHandler onError;

  /// 最近一次发起（且未失败）的进度；`null` = 本次阅读还没报过。
  ({int completedChapterCount, bool completed})? _lastReported;

  final Set<Future<void>> _inFlight = <Future<void>>{};

  /// 进度与上次发起的不同就调 [send] 发起一次上报，返回是否发起。
  ///
  /// [send] 的 Future 不交还给调用方：它在后台跑完，抛错走 [onError]。
  bool report({
    required int completedChapterCount,
    required bool completed,
    required Future<void> Function() send,
  }) {
    final ({int completedChapterCount, bool completed}) next = (
      completedChapterCount: completedChapterCount,
      completed: completed,
    );
    if (_lastReported == next) return false;
    _lastReported = next;
    late final Future<void> run;
    run = Future<void>.sync(send)
        .catchError((Object error, StackTrace stack) {
          // 这份进度没报出去：忘掉它，下一次落库再报。期间已经发起了更新的
          // 进度就不动——那一份自己负责自己。
          if (_lastReported == next) _lastReported = null;
          onError(error, stack);
        })
        .whenComplete(() => _inFlight.remove(run));
    _inFlight.add(run);
    return true;
  }

  /// 在途的上报全部结束（成功或失败）后完成；不抛错。
  Future<void> whenSettled() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
  }
}
