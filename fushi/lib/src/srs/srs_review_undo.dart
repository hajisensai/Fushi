/// 复习撤销栈：挂在 [SrsDbStore] 实例上，不挂在复习页 State 上。
///
/// 以前撤销栈是 `_SrsReviewPageState` 的字段，退出复习页（State dispose）整栈随之丢失，
/// 重新进入复习页后「撤销」不可用（反馈 gvyN7EzzDD）。Anki 的撤销队列属于 Collection，
/// 离开复习界面再回来照样能撤上一次评分；这里同理按 store 持有：
///
/// - 与 store 同生命周期（[Expando]）：切 profile / 关模块时 [srsStoreProvider] 换了 store，
///   旧栈随旧 store 一起回收，不会把别的 profile 的评分撤到当前库上。
/// - 进程内、不落库：重启 app 后为空（与 Anki 关闭集合后撤销队列清空一致）。
/// - 评分撤销仍走 [SrsDbStore.undo] 的历史校验（别的设备已复习过这张卡时返回 false）。
/// - 栈深上限 [kSrsReviewUndoLimit]，超出丢最早一步。
library;

import 'package:fushi_engine/srs/srs_db_store.dart';

/// 撤销栈最多保留的步数（超出丢最早的）。
const int kSrsReviewUndoLimit = 50;

/// 撤销栈的一步。[logId] 非 null = 撤一条评分 / 重置日志；否则执行 [revert] 改回原值。
class SrsReviewUndoStep {
  const SrsReviewUndoStep({required this.cardId, this.logId, this.revert})
    : assert(logId != null || revert != null);

  final String cardId;
  final String? logId;
  final Future<void> Function(SrsDbStore store)? revert;
}

/// 一个 store 的复习撤销栈（[SrsReviewUndoStack.of]）。
class SrsReviewUndoStack {
  SrsReviewUndoStack._();

  static final Expando<SrsReviewUndoStack> _stacks =
      Expando<SrsReviewUndoStack>('srsReviewUndo');

  /// [store] 的撤销栈；首次访问时建。
  static SrsReviewUndoStack of(SrsDbStore store) =>
      _stacks[store] ??= SrsReviewUndoStack._();

  final List<SrsReviewUndoStep> _steps = <SrsReviewUndoStep>[];

  bool get isEmpty => _steps.isEmpty;
  bool get isNotEmpty => _steps.isNotEmpty;
  int get length => _steps.length;

  void push(SrsReviewUndoStep step) {
    _steps.add(step);
    if (_steps.length > kSrsReviewUndoLimit) _steps.removeAt(0);
  }

  /// 弹出最近一步；空栈返回 null。
  SrsReviewUndoStep? pop() => _steps.isEmpty ? null : _steps.removeLast();
}
