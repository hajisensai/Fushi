import 'dart:async';

/// 把「读一份最新快照」的突发请求合并成串行读取，且**不丢请求**。
///
/// 读取进行中再来请求：不并发再读，只给本轮记一笔「再读一次」，当前这次读完立刻补读；
/// 一轮里来多少次请求都只补读一次。每个请求者拿到的 Future 都在「本次请求之后才开始的
/// 那次读取」完成后完成——所以 `await request(...)` 之后看到的一定是请求之后的快照。
///
/// 为什么需要它（BUG-3315 审查）：mpv 比值订阅只在值真的变了时来一次事件。若读取进行
/// 中来的事件直接复用在途读取，而在途读取读到的恰是变化之前的值，这次变化就永远丢了
/// ——静止的蓝光菜单状态只变一次、又恰好撞上在途采样时，界面就停在旧状态。
class CoalescedRereader {
  _RereadRound? _current;

  /// 是否有一轮读取正在进行。
  bool get isReading => _current != null;

  /// 请求一次读取。[read] 读一份快照；[stillWanted] 在补读前判断是否还值得读（换片 /
  /// 销毁后返回 false，本轮就此结束）。在途时传入的 [read] / [stillWanted] 不会被使用，
  /// 本轮沿用开轮时的那一对。
  Future<void> request(
    Future<void> Function() read, {
    required bool Function() stillWanted,
  }) {
    final _RereadRound? current = _current;
    if (current != null) {
      current.again = true;
      return current.done.future;
    }
    final _RereadRound round = _RereadRound();
    _current = round;
    unawaited(_drive(round, read, stillWanted));
    return round.done.future;
  }

  /// 作废在途的一轮：之后的请求开新的一轮。旧轮次仍会跑完它当前那次读取（读取自己
  /// 负责按世代丢弃过期结果），但不再接收新请求。
  void reset() {
    _current = null;
  }

  Future<void> _drive(
    _RereadRound round,
    Future<void> Function() read,
    bool Function() stillWanted,
  ) async {
    Object? error;
    StackTrace? stack;
    try {
      do {
        round.again = false;
        await read();
      } while (round.again && stillWanted());
    } catch (e, s) {
      error = e;
      stack = s;
    }
    // 先摘掉本轮再完成：等待者恢复执行时发起的新请求必须开新的一轮。
    if (identical(_current, round)) _current = null;
    if (error != null) {
      round.done.completeError(error, stack);
    } else {
      round.done.complete();
    }
  }
}

class _RereadRound {
  bool again = false;
  final Completer<void> done = Completer<void>();
}
