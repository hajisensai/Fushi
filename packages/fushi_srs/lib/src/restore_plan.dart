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
///   这种卡由 [srsPlanStateRestore] 补回备份时的状态，按优先级：
///   1. **重放副本**（首选）：被撤销的恰好是备份时有效历史的一段尾巴（交互层只许撤销末条，这是常态）时，
///      把那段尾巴按原顺序重新写一遍——每条照抄原日志的种类 / 评分 / 发生时刻 / 结果，只换新 ID 与新 HLC。
///      恢复后的有效历史与备份时逐条同构，任何版本的客户端按自己原有的规则算出的卡片状态与记忆状态
///      都与备份时一致：**不依赖新规则，旧版本客户端不会分歧**。
///   2. **照抄状态的 manual 日志**（兜底）：不是尾巴（例如对端撤销了中间一条、或 S 到达后排序变了），
///      写一条 manual 日志照抄备份时的状态，它同时是记忆状态 S/D 的起点（铁律 A ③′，见
///      native/fushi_fsrs/src/projection.rs `is_restore_state`）。不认识 ③′ 的旧版本（≤ 2.10.0）能读出同样的卡片状态（结果在日志里），
///      但在旧版本上**对这张卡的下一次评分**会从剩下的有效评分重算 S/D，与新版本不同（结果仍写进日志，
///      之后各端读到的都是同一个状态；分歧只在「哪台设备算这一次」）。
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

/// 撤销之后，卡片状态仍与备份时不同（备份里的末段有效日志后来被撤销了，或排序后来变了）：给出补回
/// 备份时状态的日志（见库注释的两级策略）。状态一致时返回空列表。
///
/// [current] 是这张卡（含更改笔记类型继承的前身卡）在本机的完整历史，已含 [srsPlanRevokeLogs] 写出的撤销。
List<SrsReviewLog> srsPlanStateRestore({
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
  if (current.state == want) return const <SrsReviewLog>[];

  final List<SrsReviewLog> replay = _planReplayTail(
    current: current,
    atBackup: atBackup,
    ctx: ctx,
    backupId: backupId,
    serverTimeOf: serverTimeOf,
  );
  if (replay.isNotEmpty) return replay;

  return <SrsReviewLog>[
    _restoreEvent(
      cardId: cardId,
      kind: SrsLogKind.manual,
      ctx: ctx,
      backupId: backupId,
      result: want,
      // 结果里的记忆状态是哪种算法算的：下次评分以它为起点时要同算法才直接用（srsCollectMemoryInput）。
      memAlg: atBackup.lastEffective?.algorithmEnum?.wire,
    ),
  ];
}

/// 重放副本：当前有效历史是备份时有效历史的真前缀、缺的那段尾巴全是被撤销的，就按原顺序给尾巴写副本。
/// 写完再核一遍「有效历史逐条同构 + 状态一致」，不满足返回空列表（交给兜底）。
List<SrsReviewLog> _planReplayTail({
  required SrsCardHistory current,
  required SrsCardHistory atBackup,
  required SrsLogContext ctx,
  required String backupId,
  int? Function(String eventId)? serverTimeOf,
}) {
  final List<SrsReviewLog> cur = current.effective;
  final List<SrsReviewLog> bak = atBackup.effective;
  if (cur.length >= bak.length) return const <SrsReviewLog>[];
  for (int i = 0; i < cur.length; i++) {
    if (cur[i].id != bak[i].id) return const <SrsReviewLog>[];
  }
  final List<SrsReviewLog> tail = bak.sublist(cur.length);
  if (!tail.every((SrsReviewLog l) => current.revoked.contains(l.id))) {
    return const <SrsReviewLog>[];
  }
  final List<SrsReviewLog> copies = <SrsReviewLog>[
    for (final SrsReviewLog l in tail) _replayOf(l, ctx, backupId),
  ];
  final SrsCardHistory after = SrsCardHistory(<SrsReviewLog>[
    ...current.all,
    ...copies,
  ], serverTimeOf: serverTimeOf);
  if (!srsSameEffectiveShape(after.effective, bak) ||
      after.state != atBackup.state) {
    return const <SrsReviewLog>[];
  }
  return copies;
}

/// 两段有效历史逐条同构：种类、卡、评分、复习类型、发生时刻、结果都相同（ID / HLC 不比）。
/// 同构的两段历史，任何版本按自己的规则算出的卡片状态与记忆状态输入都相同。
bool srsSameEffectiveShape(List<SrsReviewLog> a, List<SrsReviewLog> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    final SrsReviewLog x = a[i];
    final SrsReviewLog y = b[i];
    if (x.kind != y.kind ||
        x.cardId != y.cardId ||
        x.rating != y.rating ||
        x.reviewType != y.reviewType ||
        x.occurredAt != y.occurredAt ||
        x.origin != y.origin ||
        x.ankiRevlogId != y.ankiRevlogId ||
        x.algorithm != y.algorithm ||
        x.result != y.result) {
      return false;
    }
  }
  return true;
}

/// 一条日志的重放副本：照抄内容，只换新 ID / 新 HLC，extra 里记上来源备份与原日志 ID（追溯用）。
SrsReviewLog _replayOf(SrsReviewLog l, SrsLogContext ctx, String backupId) {
  final (int nowMs, _) = ctx.now();
  return SrsReviewLog(
    id: ctx.newId(nowMs),
    profileUid: l.profileUid,
    cardId: l.cardId,
    kind: l.kind,
    rating: l.rating,
    hlc: ctx.clock.tick(nowMs),
    occurredAt: l.occurredAt,
    timeSource: l.timeSource,
    origin: l.origin,
    reviewType: l.reviewType,
    durationMs: l.durationMs,
    paramsHash: l.paramsHash,
    algorithm: l.algorithm,
    utcOffsetMin: l.utcOffsetMin,
    dayRolloverHour: l.dayRolloverHour,
    result: l.result,
    ankiRevlogId: l.ankiRevlogId,
    extra: <String, Object?>{
      ...l.extra,
      srsRestoreLogExtraKey: backupId,
      srsReplayOfLogExtraKey: l.id,
    },
    formatVersion: l.formatVersion,
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
