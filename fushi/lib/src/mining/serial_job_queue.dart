import 'dart:async';

/// 串行任务队列：把异步任务排成一条链依次执行，每个任务的返回 future 独立完成。
///
/// 根因修复（BUG-956）：原先两处（GalHookMiningCoordinator.mineLine /
/// GalHookSessionController._captureAudioBytes）各自手写 `_tail = _tail.then(job)`，
/// 但链尾没有 `catchError` 归位——一旦某个任务的**错误处理路径自身抛异常**（日志服务抛、
/// completer 二次完成的 StateError 等），`.then` 返回的 future 变成 rejected，后续
/// `_tail.then(onValue)` 的 onValue 永不触发、其 completer 永不完成 → 制卡永久挂起。
///
/// 本原语把「串行 + 永不毒化 + completer 一定完成」封装为一处并加测试守卫：
/// - [enqueue] 内部 try/catch 任务异常，用 [buildFailure] 造降级结果完成 completer；
/// - 链尾再挂 `catchError` 兜住任何逃逸异常（含 [onError] / [buildFailure] 自身抛）；
/// - `settle` 全程吞掉副作用异常，保证 `_tail` 永远 resolve 成功、下个任务照常执行。
class SerialJobQueue {
  Future<void> _tail = Future<void>.value();

  /// 入队一个任务 [job]，返回其结果 future（与队列链解耦，一定会完成）。
  ///
  /// [buildFailure]：任务抛异常时据 error/stack 构造降级结果（必须是纯构造、尽量不抛；
  /// 万一它也抛，会退化为 completeError）。[onError]：可选副作用（如写日志），其异常被吞。
  Future<T> enqueue<T>(
    Future<T> Function() job, {
    required T Function(Object error, StackTrace stack) buildFailure,
    void Function(Object error, StackTrace stack)? onError,
  }) {
    final Completer<T> completer = Completer<T>();

    void settle(Object error, StackTrace stack) {
      if (onError != null) {
        try {
          onError(error, stack);
        } catch (_) {
          // 副作用（日志等）自身抛不得毒化队列或阻塞 completer。
        }
      }
      if (completer.isCompleted) {
        return;
      }
      try {
        completer.complete(buildFailure(error, stack));
      } catch (_) {
        // buildFailure 极端情况下也抛：退化为把原始错误抛给调用方，仍保证 completer 完成。
        if (!completer.isCompleted) {
          completer.completeError(error, stack);
        }
      }
    }

    _tail = _tail.then((_) async {
      try {
        completer.complete(await job());
      } catch (error, stack) {
        settle(error, stack);
      }
    }).catchError((Object error, StackTrace stack) {
      // 兜底：串行链绝不能停在 rejected 状态，否则后续 enqueue 的 .then(onValue) 永不触发。
      settle(error, stack);
    });

    return completer.future;
  }

  /// 与 [enqueue] 相同地串行执行，但任务失败时把原始异常交还调用方，而不是构造
  /// 降级结果。队列链本身仍会归位，所以下一个任务不会被前一个失败毒化。
  Future<T> enqueueRethrowing<T>(
    Future<T> Function() job, {
    void Function(Object error, StackTrace stack)? onError,
  }) {
    return enqueue<T>(
      job,
      buildFailure: (Object error, StackTrace stack) =>
          Error.throwWithStackTrace(error, stack),
      onError: onError,
    );
  }
}
