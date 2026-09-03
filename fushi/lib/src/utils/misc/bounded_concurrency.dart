/// 有界并发原语：跨源扇出（发现聚合 / 漫画全源搜索）的共用实现。
/// 此前漫画页私有一份、发现服务再抄一份——两份同形代码就该收一处。
library;

import 'dart:collection';

/// 有上限并发地跑 [items]，每项调 [task]；一项抛错会中断所在 worker，
/// 调用方应在 [task] 内部兜住异常（两处调用点均如此）。
Future<void> runBoundedTasks<T>(
  List<T> items, {
  required int maxConcurrent,
  required Future<void> Function(T item) task,
}) async {
  final Queue<T> pending = Queue<T>.of(items);
  Future<void> worker() async {
    while (pending.isNotEmpty) {
      await task(pending.removeFirst());
    }
  }

  final int workers = maxConcurrent < items.length
      ? maxConcurrent
      : (items.isEmpty ? 0 : items.length);
  await Future.wait<void>(
    <Future<void>>[for (int i = 0; i < workers; i++) worker()],
  );
}
