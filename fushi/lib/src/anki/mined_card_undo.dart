/// 撤回刚制的卡 / 删除已制卡（反馈 JNyykxvuY9）的唯一执行点。
///
/// 两个入口共用这里：
/// * 制卡成功提示上的「撤销」（`FushiToast.showMine(undo: …)`，视频页 OSD 同理）；
/// * 已制卡 ✓ 对话框里的「从 Anki 删除这张卡」（`showAnkiMinedCardActionSheet`）。
///
/// 删除本身由后端做（[BaseAnkiRepository.deleteMinedNote]：AnkiConnect `deleteNotes`
/// / AnkiDroid ContentProvider / Fushi 复习 Rust 核心删除走同步墓碑）；这里负责门控
/// （后端删不了就**不给**按钮）、留痕，以及删完让正在显示 ✓ 的界面重新查一次
/// （[MinedStateSignal]——查词弹窗据此重问 `duplicateCheck`，✓ 变回 +）。
library;

import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/anki/mined_state_signal.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/i18n/strings.g.dart';

/// 一次删除的结局。
enum MinedCardDeleteResult {
  /// 删掉了。
  deleted,

  /// 后端明确回答这张 note 已经不在了（别处先删了）。
  alreadyGone,

  /// 删除请求失败（后端不可达 / 出错），卡可能还在。
  failed,
}

/// 删掉 [noteId] 并通知制卡态变了。[expression] 已知时只让这个词重新探测。
Future<MinedCardDeleteResult> deleteMinedCard({
  required BaseAnkiRepository repo,
  required int noteId,
  String? expression,
}) async {
  final MinedCardDeleteResult result;
  try {
    result = await repo.deleteMinedNote(noteId)
        ? MinedCardDeleteResult.deleted
        : MinedCardDeleteResult.alreadyGone;
  } catch (e, stack) {
    ErrorLogService.instance.log('deleteMinedCard', e, stack);
    return MinedCardDeleteResult.failed;
  }
  final String word = expression?.trim() ?? '';
  if (word.isEmpty) {
    MinedStateSignal.instance.notifyAll();
  } else {
    MinedStateSignal.instance.notifyWord(word);
  }
  return result;
}

/// 制卡成功提示上「撤销」按钮背后的动作。
///
/// 只由 [MinedCardUndo.of] 构造：拿得到 note id、且后端删得了时才有；否则为 null，
/// 提示上就不出按钮（AnkiMobile、互联转发、进了待发队列的卡都属于这一类）。
class MinedCardUndo {
  const MinedCardUndo._({
    required this.repo,
    required this.noteId,
    required this.expression,
  });

  /// 成功制卡（不含覆写、不含进待发队列）且后端支持删除时返回撤销动作。
  static MinedCardUndo? of(
    BaseAnkiRepository repo,
    MineOutcome outcome, {
    String? expression,
  }) {
    final int? noteId = outcome.noteId;
    if (outcome.result != MineResult.success || noteId == null) return null;
    if (!repo.canDeleteMinedNotes) return null;
    return MinedCardUndo._(repo: repo, noteId: noteId, expression: expression);
  }

  final BaseAnkiRepository repo;
  final int noteId;
  final String? expression;

  /// 删掉刚加的卡。
  Future<MinedCardDeleteResult> run() =>
      deleteMinedCard(repo: repo, noteId: noteId, expression: expression);
}

/// 删除结局的用户文案（toast 与视频 OSD 共用）。
String minedCardDeleteResultText(MinedCardDeleteResult result) =>
    switch (result) {
      MinedCardDeleteResult.deleted => t.anki_mined_card_deleted,
      MinedCardDeleteResult.alreadyGone => t.anki_mined_card_already_gone,
      MinedCardDeleteResult.failed => t.anki_mined_delete_failed,
    };

/// 删除结局的提示语义色。
ToastSeverity minedCardDeleteResultSeverity(MinedCardDeleteResult result) =>
    switch (result) {
      MinedCardDeleteResult.deleted => ToastSeverity.success,
      MinedCardDeleteResult.alreadyGone => ToastSeverity.info,
      MinedCardDeleteResult.failed => ToastSeverity.error,
    };

/// 制卡成功 toast 上的「撤销」按钮：[outcome] 不可撤（见 [MinedCardUndo.of]）时
/// 返回 null，toast 就不出按钮。点下删卡，结局再用一条 toast 说出来。
///
/// [overwrite]：这次是覆写已有卡（结果里的 note id 是**原来那张**）——撤销等于删掉
/// 用户原有的卡，绝不能给。
MineNoticeAction? minedCardUndoToastAction(
  BaseAnkiRepository repo,
  MineOutcome outcome, {
  String? expression,
  bool overwrite = false,
}) {
  if (overwrite) return null;
  final MinedCardUndo? undo = MinedCardUndo.of(
    repo,
    outcome,
    expression: expression,
  );
  if (undo == null) return null;
  return MineNoticeAction(
    label: t.card_notice_undo,
    onPressed: () async {
      final MinedCardDeleteResult result = await undo.run();
      FushiToast.show(
        msg: minedCardDeleteResultText(result),
        severity: minedCardDeleteResultSeverity(result),
      );
    },
  );
}
