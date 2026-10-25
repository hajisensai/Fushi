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
/// 「扫存活引用 → 删文件」若不在一个独占区里，中间插进来的编辑 / 恢复 / 撤销会重新引用某个刚判为
/// 无引用的文件，清理照旧按过期的结论删掉它，且无从找回（HBK-AUDIT-014）。所以：
/// - 扫描、删文件、移出待回收集合在**同一个** `runExclusive` 里做；库里每一种引入引用的写入都走这把锁。
/// - 媒体文件本身先于引用落盘（`SrsMediaStore.store` 写文件 / 复用同内容文件 → 之后才提交引用它的
///   笔记），这一步在锁外。为此 `store` 复用已有文件时也刷新修改时间，回收只删修改时间早于
///   [kSrsMediaGcGrace] 的文件：刚写 / 刚复用、引用可能还没提交的文件留到下一轮。
/// - 候选落进本机状态（`SrsDbStore.pendingMediaGc`）：被跳过、被叫停或中途崩溃的下次维护接着处理。
library;

import 'dart:io';

import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart' show srsMediaRefsIn;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart'
    show kSrsMediaRetention, srsLiveMediaReferences;
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

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
Future<SrsPurgeReport> srsPurgeExpiredTombstones(
  SrsDbStore store, {
  Directory? mediaRoot,
  Duration after = kSrsMediaRetention,
  Duration mediaGrace = kSrsMediaGcGrace,
}) async {
  final SrsPurgeReport report = SrsPurgeReport();
  if (mediaRoot == null) return report;
  final int cutoff = store.now().$1 - after.inMilliseconds;
  await store.queueMediaGc(await store.expiredNoteMediaRefs(cutoff));
  if (store.pendingMediaGc.isNotEmpty) {
    report.mediaFiles = await _collectPendingMedia(
      store,
      mediaRoot,
      grace: mediaGrace,
      retention: after,
    );
  }
  return report;
}

/// 用户确认后彻底清除 [noteIds]（例如删牌组时选了「永久删除」）：每条一个 v2 `Purge`（先删除、再清除内容，
/// 全网一致）；它们引用过的、此刻没有存活引用的媒体随后回收。
Future<SrsPurgeReport> srsPurgeNotesNow(
  SrsDbStore store,
  List<String> noteIds, {
  Directory? mediaRoot,
  Duration mediaGrace = kSrsMediaGcGrace,
}) async {
  final SrsPurgeReport report = SrsPurgeReport();
  final Set<String> media = <String>{};
  for (final SrsNoteView? n in (await store.notes(noteIds)).values) {
    if (n == null) continue;
    for (final String v in n.fields.values) {
      media
        ..addAll(srsMediaRefsIn(v))
        ..addAll(srsStyleRefsIn(v));
    }
  }
  for (final String id in noteIds) {
    await store.sync2Purge(SrsEntityKind.note, id);
    report.notes++;
  }
  if (mediaRoot != null && media.isNotEmpty) {
    await store.queueMediaGc(media);
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

/// 回收待回收集合里此刻没有任何存活引用、且过了宽限期的文件（只删 [mediaRoot] 下的裸文件名）。
///
/// 扫描、删除、移出集合全程在一个独占区里（见库注释）。比较不区分大小写：Windows / macOS 默认卷上
/// 大小写不同的两个名字是同一个文件。
Future<int> _collectPendingMedia(
  SrsDbStore store,
  Directory mediaRoot, {
  required Duration grace,
  required Duration retention,
}) => store.runExclusive(() async {
  final Set<String> alive = <String>{
    for (final String n in await srsLiveMediaReferences(
      store,
      retention: retention,
    ))
      n.toLowerCase(),
  };
  final DateTime freshAfter = DateTime.now().subtract(grace);
  final List<String> settled = <String>[];
  int deleted = 0;
  for (final String name in store.pendingMediaGc) {
    // 又被引用了：不是垃圾。以后引用它的笔记删除满保留期时会重新成为候选。
    if (!_isBareName(name) || alive.contains(name.toLowerCase())) {
      settled.add(name);
      continue;
    }
    final File f = File(p.join(mediaRoot.path, name));
    final FileStat st = await f.stat();
    if (st.type == FileSystemEntityType.notFound) {
      settled.add(name);
      continue;
    }
    // 刚写 / 刚复用：引用它的笔记可能还没提交，留到下一轮。
    if (st.modified.isAfter(freshAfter)) continue;
    try {
      await f.delete();
      deleted++;
      settled.add(name);
    } on FileSystemException {
      // 被占用（Windows 上正在播放 / 预览）：留在集合里，下一轮再试。
    }
  }
  await store.settlePendingMediaGc(settled);
  return deleted;
});

bool _isBareName(String n) =>
    n.isNotEmpty &&
    !n.contains('/') &&
    !n.contains(r'\') &&
    !n.contains(':') &&
    n != '.' &&
    n != '..';
