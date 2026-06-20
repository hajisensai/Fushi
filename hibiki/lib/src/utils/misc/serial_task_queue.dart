import 'dart:async';

/// 单生产者串行任务队列：把异步任务挂到一条 [Future] 链尾，保证同一时刻只跑一个任务的
/// 完整 prepare→执行序列。前一个任务（成功或抛出）完成前，下一个不启动。
///
/// TODO-644 / BUG-357：制卡链路用它把 `onMineFromPopup` / `onUpdateFromPopup` 串行化。
/// 快速连制两张卡（来自两个 mine button，popup.js 的 per-button guard 互不影响）时，
/// 第二张排队等第一张完成后再跑，杜绝两次制卡 prepare 在 `extractAudioSegment` 的 await
/// 处交错改写共享成员。排队而非丢弃，保证「两张卡都正确」。
///
/// 失败语义：前一个任务抛出的异常不会阻断队列——队列尾推进到「本次完成（含失败）」之后，
/// 失败被队列内部吞掉（调用方拿到的 future 仍正常 rethrow，可各自记日志/弹 toast）。
class SerialTaskQueue {
  /// 队列尾。初始为已完成的空 future，第一个任务立即可跑。
  Future<void> _tail = Future<void>.value();

  /// 把 [task] 挂到队列尾并返回其结果 future。[task] 在前一个任务完成（含失败）后才启动。
  ///
  /// 返回的 future 反映 [task] 自身的成功/失败（失败会 rethrow 给调用方）；队列尾对失败
  /// 免疫，后续任务不被前一次异常卡死。
  Future<T> enqueue<T>(Future<T> Function() task) {
    final Future<T> result = _tail.then<T>((_) => task());
    _tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }
}
