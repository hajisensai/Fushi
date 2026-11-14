/// 复习库的空间回收（docs/specs/2026-10-25-srs-sync-v2-design.md §10.2、§10.5）。
///
/// 同步 v2 的历史永久保留：删除只是一条操作，笔记正文、复习日志都还在操作日志与投影里（时间线恢复要用；
/// 各设备的投影也必须逐行一致，按本机时钟删行会让它们分叉）。所以这里**不再物理删行**，只做两件事：
///
/// 1. **媒体保留期**（自动维护，[srsPurgeExpiredTombstones]）：只被「删除已满 [kSrsMediaRetention]」的笔记
///    引用、且不被任何存活引用的本机媒体文件 → 删。保留期内恢复笔记媒体还在；之后恢复，文字回来、媒体
///    显示缺失（有归档位置就从那里补回）。同步 / 媒体位置上的同一批文件由 srs_media_sync.dart 按同一口径清。
/// 2. **彻底清除**（用户确认，[srsPurgeNotesNow]）：每条笔记追加 v2 的 `Purge` 操作——各设备收到后把本机
///    日志里它的内容载荷换成哈希、删掉投影里的内容、重写自己写过的段（全系统唯一改写历史的操作），然后
///    回收它独占的媒体。
///
/// ## 媒体回收与并发写入的契约
///
/// 「扫存活引用 → 删文件」必须对写入原子：中间插进来的编辑 / 恢复 / 撤销 / 对端事件会重新引用某个刚判为无引用的
/// 文件，清理照旧按过期的结论删掉它，且无从找回（HBK-AUDIT-014）。所以：
/// - 核对存活引用、删文件、移出待回收集合是内核的**一条命令**（`media_gc_collect`，
///   native/fushi_fsrs/src/store/media_gc.rs；[SrsDbStore.collectPendingMedia]）：在内核的写锁里、一笔里做，
///   库里每一种引入引用的写入都要这把锁。存活引用的口径也只在内核一处。
/// - 媒体文件本身先于引用落盘（`SrsMediaStore.store` 写文件 / 复用同内容文件 → 之后才提交引用它的
///   笔记），这一步在锁外。为此 `store` 复用已有文件时也刷新修改时间，回收只删修改时间早于
///   [kSrsMediaGcGrace] 的文件：刚写 / 刚复用、引用可能还没提交的文件留到下一轮。
/// - 候选落进本机状态行（内核持有的 `mediaGc`，[SrsDbStore.pendingMediaGc]）：被跳过、被叫停或中途崩溃的下次
///   维护接着处理。
library;

import 'dart:io';
import 'dart:math';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart' show kSrsMediaRetention;
import 'package:fushi_srs/fushi_srs.dart';

/// 媒体回收宽限期：修改时间在这之内的文件不删（见库注释「媒体回收与并发写入的契约」）。
const Duration kSrsMediaGcGrace = Duration(hours: 24);

/// 一次回收做了什么。
class SrsPurgeReport {
  /// 彻底清除的笔记数（只有 [srsPurgeNotesNow] 会清）。
  int notes = 0;
  int mediaFiles = 0;

  @override
  String toString() => 'SrsPurgeReport(notes=$notes, media=$mediaFiles)';
}

/// 维护：回收过了保留期的媒体（store 打开后在后台跑）。[mediaRoot] 为 null 时什么也不做。
///
/// [shouldStop]：每一步（收候选、回收）之前看一次，返回 true 就收手（store 换掉 / 副本开始作废）；候选已持久化在
/// 本机状态里，下次打开接着回收。
Future<SrsPurgeReport> srsPurgeExpiredTombstones(
  SrsDbStore store, {
  Directory? mediaRoot,
  Duration after = kSrsMediaRetention,
  Duration mediaGrace = kSrsMediaGcGrace,
  bool Function()? shouldStop,
}) async {
  final SrsPurgeReport report = SrsPurgeReport();
  if (mediaRoot == null) return report;
  bool stopped() => shouldStop?.call() ?? false;
  if (stopped()) return report;
  final int cutoff = store.now().$1 - after.inMilliseconds;
  final Set<String> pending = await store.queueMediaGcOf(
    expiredBeforeMs: cutoff,
  );
  if (stopped() || pending.isEmpty) return report;
  report.mediaFiles = await _collectPendingMedia(
    store,
    mediaRoot,
    grace: mediaGrace,
    retention: after,
    shouldStop: shouldStop,
  );
  return report;
}

/// 一条 `purge` 命令清除的笔记数上限（[srsPurgeNotesNow] 的分块）：一条命令一笔事务，连同缓存重放与 WAL 都随
/// 条数增长；逐条发（以前）则每条笔记各付一次事务、缓存刷新与本机状态行。
const int kSrsPurgeChunk = 200;

/// 用户确认后彻底清除 [noteIds]（例如删牌组时选了「永久删除」）：每条一个 v2 `Purge`（先删除、再清除内容，
/// 全网一致），每 [kSrsPurgeChunk] 条一条内核命令、一笔（中途出错：已经做完的块留着，这一块整块不落）；它们
/// 引用过的、此刻没有存活引用的媒体随后回收。
Future<SrsPurgeReport> srsPurgeNotesNow(
  SrsDbStore store,
  List<String> noteIds, {
  Directory? mediaRoot,
  Duration mediaGrace = kSrsMediaGcGrace,
}) async {
  final SrsPurgeReport report = SrsPurgeReport();
  // 清除会抹掉字段：先把它们此刻引用的媒体记进待回收集合（没有媒体目录的副本从不回收，不记）。
  final bool queued =
      mediaRoot != null &&
      (await store.queueMediaGcOf(notes: noteIds)).isNotEmpty;
  for (int i = 0; i < noteIds.length; i += kSrsPurgeChunk) {
    final List<String> chunk = noteIds.sublist(
      i,
      min(i + kSrsPurgeChunk, noteIds.length),
    );
    await store.sync2PurgeMany(SrsEntityKind.note, chunk);
    report.notes += chunk.length;
  }
  if (queued) {
    report.mediaFiles = await _collectPendingMedia(
      store,
      mediaRoot,
      grace: mediaGrace,
      // 回收站里删除未满保留期的笔记仍算存活引用：只回收被清除的这些笔记独占的媒体（清除抹掉了它们的
      // 字段，它们自己不再引用任何文件）。
      retention: kSrsMediaRetention,
    );
  }
  return report;
}

/// 回收待回收集合里此刻没有任何存活引用、且过了宽限期的文件（只删 [mediaRoot] 下的裸文件名）：策略（保留期、
/// 宽限期）在这里，「核对存活引用 → 删文件 → 移出集合」在内核（见库注释）。
Future<int> _collectPendingMedia(
  SrsDbStore store,
  Directory mediaRoot, {
  required Duration grace,
  required Duration retention,
  bool Function()? shouldStop,
}) => store.collectPendingMedia(
  mediaRoot.path,
  aliveAfterMs: store.now().$1 - retention.inMilliseconds,
  freshAfterMs: DateTime.now().subtract(grace).millisecondsSinceEpoch,
  shouldStop: shouldStop,
);
