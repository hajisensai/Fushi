/// 「恢复到某个备份时间点」在事件溯源模型里的表达（docs/specs/2026-10-17-srs-auto-backup-restore.md）。
///
/// 事件只追加、按 ID 取并集，删掉事件不会传播：别的设备手里有的事件下一轮同步就回来了。
/// 所以「回到过去」不能靠删数据或把库整个换掉，只能**写新事件**，让新事件在合并里赢过备份之后的一切：
///
/// - 可编辑字段（铁律 H）：给每个与备份值不同的字段键写一条新修改记录，值取备份时的值。新记录的 ctx
///   覆盖本机已应用的全部记录，所以支配它们；对端把这条记录合进去之后同样被支配，旧值回不来。
///   这一部分不在本文件（直接走 SrsDbStore 的普通写路径），本文件只给复习日志出计划。
/// - 复习日志（铁律 A / B）：日志不可变、只追加。备份之后的有效日志用 undo 撤销（[srsPlanRevokeLogs]），
///   撤销是永久的、随同步传播，各端都把它们排除出卡片状态、统计与训练集。
///   被备份之后某次撤销拿掉的备份内日志不能「撤销撤销」（有效日志的定义里 revoked 只看 revokesId），
///   这种卡写一条 manual 日志，结果照抄备份时的卡片状态（[srsPlanStateRestore]）。它同时是记忆状态
///   S/D 的起点（铁律 A ③′，见 valid_logs.dart [srsIsRestoreState]）：被撤销的评分已不在有效历史里，
///   不从它起算，下次评分就会从零重算、与备份时那张卡对不上。
///
/// 这是协议里唯一允许撤销「非最后一条有效日志」的地方：合并语义对任意 revokesId 都有定义
/// （valid_logs.dart），「只许撤销末条」是交互层的限制，用来避免撤销基于别人后续复习的旧评分；
/// 恢复的语义正是「备份之后的评分全部不算」，与这条限制的初衷不冲突。
library;

import 'card_ops.dart';
import 'hlc.dart';
import 'review_log.dart';
import 'valid_logs.dart';

/// 一组日志（通常是同一张卡的全部日志）里「当前有效、但不在备份里」的日志，逐条写 undo。
///
/// 按 sortKey 从新到旧撤销：备份最后一条之后的那段就是连续撤销（与复习页的连续撤销同形），
/// 夹在备份日志之间的（备份那一刻本机还没收到的别的设备的复习）同样撤销，恢复后有效日志集合
/// = 备份时的有效日志集合（减去之后被撤销的）。
List<SrsReviewLog> srsPlanRevokeLogs({
  required Iterable<SrsReviewLog> logs,
  required Set<String> backupLogIds,
  required SrsLogContext ctx,
  required String backupId,
  int? Function(String eventId)? serverTimeOf,
}) {
  final SrsCardHistory h = SrsCardHistory(logs, serverTimeOf: serverTimeOf);
  final List<SrsReviewLog> out = <SrsReviewLog>[];
  for (final SrsReviewLog l in h.effective.reversed) {
    if (backupLogIds.contains(l.id)) continue;
    out.add(
      _restoreEvent(
        cardId: l.cardId,
        kind: SrsLogKind.undo,
        ctx: ctx,
        backupId: backupId,
        revokesId: l.id,
      ),
    );
  }
  return out;
}

/// 撤销之后，卡片状态仍与备份时不同（备份里的最后一条有效日志后来被撤销了，或排序后来变了）：
/// 写一条 manual 日志，结果照抄备份时的状态。状态一致时返回 null。
///
/// [current] 是这张卡（含更改笔记类型继承的前身卡）在本机的完整历史，已含 [srsPlanRevokeLogs] 写出的撤销。
SrsReviewLog? srsPlanStateRestore({
  required String cardId,
  required SrsCardHistory current,
  required Set<String> backupLogIds,
  required SrsLogContext ctx,
  required String backupId,
  int? Function(String eventId)? serverTimeOf,
}) {
  final SrsCardHistory atBackup = SrsCardHistory(
    current.all.where((SrsReviewLog l) => backupLogIds.contains(l.id)),
    serverTimeOf: serverTimeOf,
  );
  final SrsScheduleResult want = atBackup.state;
  if (current.state == want) return null;
  return _restoreEvent(
    cardId: cardId,
    kind: SrsLogKind.manual,
    ctx: ctx,
    backupId: backupId,
    result: want,
    // 结果里的记忆状态是哪种算法算的：下次评分以它为起点时要同算法才直接用（srsCollectMemoryInput）。
    memAlg: atBackup.lastEffective?.algorithmEnum?.wire,
  );
}

SrsReviewLog _restoreEvent({
  required String cardId,
  required String kind,
  required SrsLogContext ctx,
  required String backupId,
  String? revokesId,
  SrsScheduleResult? result,
  String? memAlg,
}) {
  final (int nowMs, SrsTimeSource source) = ctx.now();
  final Hlc hlc = ctx.clock.tick(nowMs);
  return SrsReviewLog(
    id: ctx.newId(nowMs),
    profileUid: ctx.profileUid,
    cardId: cardId,
    kind: kind,
    revokesId: revokesId,
    hlc: hlc,
    occurredAt: nowMs,
    timeSource: source,
    origin: SrsLogOrigin.fushi,
    reviewType: SrsReviewType.manual,
    utcOffsetMin: ctx.day.utcOffsetMin,
    dayRolloverHour: ctx.day.rolloverHour,
    result: result,
    extra: <String, Object?>{
      srsRestoreLogExtraKey: backupId,
      if (memAlg != null) 'memAlg': memAlg,
    },
  );
}
