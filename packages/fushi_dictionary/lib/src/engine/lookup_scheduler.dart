import 'dart:async';

/// 后台查词的调度规则（纯 Dart，不碰 isolate / FFI，便于单测）。
///
/// 三条规则，都是为「查词卡手」里「最后输入为准」服务的：
///
/// 1. **同一时刻只有一个任务在执行**（[run] 串行）。后台查词 isolate 本来就是串行
///    的；把排队留在调用方（UI）这一侧，而不是一股脑塞进 isolate 的事件队列，才有
///    机会在任务真正开始之前改主意（下面两条）。
/// 2. **新的先跑**（LIFO）。用户连续移动光标时，最新那次查词只需等「当前正在跑的
///    那一个」，不必排在一长串已经没人要的旧请求后面。旧请求不丢——没有声明可被
///    取代的调用方（加载更多、批量制卡、浏览器扩展…）照样拿到自己的结果，只是让
///    最新的插队。
/// 3. **同一条 lane 只保留最新**。声明了 lane 的任务（[laneOf] 非 null）入队时，
///    同 lane 里**尚未开始**的旧任务直接以 [onDropped] 的值结束，不再执行；已经在
///    执行的不受影响（原生调用不可中断，结果照常返回，调用方靠自己的代次检查丢弃）。
///
/// [drain] 用于关停：把还没开始的任务全部以 [onDropped] 结束，再等在飞那一个跑完。
class LookupJobScheduler<J, R> {
  LookupJobScheduler({
    required Future<R> Function(J job) run,
    required R Function(J job) onDropped,
    String? Function(J job)? laneOf,
  }) : _run = run,
       _onDropped = onDropped,
       _laneOf = laneOf ?? _noLane;

  final Future<R> Function(J job) _run;
  final R Function(J job) _onDropped;
  final String? Function(J job) _laneOf;

  static String? _noLane(Object? _) => null;

  final List<_ScheduledJob<J, R>> _queue = <_ScheduledJob<J, R>>[];
  _ScheduledJob<J, R>? _running;
  Completer<void>? _idle;

  /// 还没开始执行的任务数。
  int get queuedCount => _queue.length;

  /// 是否有任务正在执行。
  bool get isRunning => _running != null;

  /// 提交一个任务；返回它的结果（被取代时为 [onDropped] 的值）。
  Future<R> submit(J job) {
    final _ScheduledJob<J, R> scheduled = _ScheduledJob<J, R>(job);
    final String? lane = _laneOf(job);
    if (lane != null) {
      _queue.removeWhere((_ScheduledJob<J, R> queued) {
        if (_laneOf(queued.job) != lane) return false;
        queued.completer.complete(_onDropped(queued.job));
        return true;
      });
    }
    _queue.add(scheduled);
    _pump();
    return scheduled.completer.future;
  }

  /// 丢弃全部未开始的任务（以 [onDropped] 结束），并等正在执行的那个结束。
  Future<void> drain() {
    for (final _ScheduledJob<J, R> queued in _queue) {
      queued.completer.complete(_onDropped(queued.job));
    }
    _queue.clear();
    if (_running == null) return Future<void>.value();
    return (_idle ??= Completer<void>()).future;
  }

  void _pump() {
    if (_running != null || _queue.isEmpty) return;
    // 规则 2：新的先跑。
    final _ScheduledJob<J, R> next = _queue.removeLast();
    _running = next;
    Future<R> result;
    try {
      result = _run(next.job);
    } catch (error, stack) {
      result = Future<R>.error(error, stack);
    }
    result
        .then<void>(
          next.completer.complete,
          onError: next.completer.completeError,
        )
        .whenComplete(() {
          _running = null;
          if (_queue.isEmpty) {
            final Completer<void>? idle = _idle;
            _idle = null;
            idle?.complete();
          }
          _pump();
        });
  }
}

class _ScheduledJob<J, R> {
  _ScheduledJob(this.job);

  final J job;
  final Completer<R> completer = Completer<R>();
}
