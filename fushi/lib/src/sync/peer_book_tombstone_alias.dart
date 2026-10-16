import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart'
    show InterconnectMangaCatalog;

/// 把对端书键的删除墓碑换算到本机对应行上（`book` / `audiobook` 共享 bookKey）。
///
/// 同一本书两端键不同时，对端「从所有设备删除」写的墓碑键与本机在库键求交恒空：
/// 不出候选、不弹确认框，删除在本机静默丢失。两类来源：
///
/// * **经互联收下的章节式在线漫画**（BUG-3443）：本机行键由对端键单向推导成
///   `interconnect-…`（[InterconnectMangaCatalog.localBookKeyFor]），只对 `book`；
/// * **从对端下载、落地键不同的书**（对端同名书带 `(2)` 后缀、EPUB 无 dc:title
///   回落到临时文件名…）：下载入库时记进 `collection_book_aliases` 的对端键，经
///   [peerToLocalBookKey]（`FushiDatabase.getPeerToLocalBookKeys`）换算。
///
/// 只**追加**别名条目（本机键 → 同一个 deletedAt），不改原条目：候选、标题解析、
/// 基线守卫、确认后的删除全按本机键走，下游零特判；原键本机不在库，本来就不出候选。
/// 原键本机也在库（两端碰巧同键的另一本）时不追加，免得一条删除弹两次。
void aliasPeerBookTombstones(
  DeletionTombstoneEntries remoteTombstones,
  DeletionPresentEntries localPresent, {
  required Map<String, String> peerToLocalBookKey,
}) {
  for (final SyncTombstoneKind kind in <SyncTombstoneKind>[
    SyncTombstoneKind.book,
    SyncTombstoneKind.audiobook,
  ]) {
    final Map<String, int>? remote = remoteTombstones[kind.dbValue];
    final Map<String, int?>? present = localPresent[kind.dbValue];
    if (remote == null || present == null) continue;
    final Map<String, int> aliases = <String, int>{};
    void alias(String? localKey, int deletedAt) {
      if (localKey == null || !present.containsKey(localKey)) return;
      final int? prev = remote[localKey] ?? aliases[localKey];
      if (prev == null || deletedAt > prev) aliases[localKey] = deletedAt;
    }

    remote.forEach((String peerKey, int deletedAt) {
      if (present.containsKey(peerKey)) return;
      alias(peerToLocalBookKey[peerKey], deletedAt);
      if (kind == SyncTombstoneKind.book) {
        alias(InterconnectMangaCatalog.localBookKeyFor(peerKey), deletedAt);
      }
    });
    remote.addAll(aliases);
  }
}
