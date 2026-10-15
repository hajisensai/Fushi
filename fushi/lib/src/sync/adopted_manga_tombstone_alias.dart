import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart'
    show InterconnectMangaCatalog;

/// 把对端 `book/<对端 bookKey>` 删除墓碑换算到本机经互联收下的那一行上。
///
/// 对端的章节式在线漫画（Mihon 等）被本机「下载」时，收成一条 runtime=interconnect
/// 的在线书架行，bookKey 由对端 bookKey **重新推导**（`interconnect-…`，见
/// [InterconnectMangaCatalog.localBookKeyFor]）。对端勾「从所有设备删除」写的墓碑键是
/// 它自己的 `mihon-…`，与本机在库键求交恒空——不出候选、不弹确认框，删除在本机静默
/// 丢失。
///
/// 这里只**追加**别名条目（本机键 → 同一个 deletedAt），不改原条目：候选、标题解析、
/// 确认后的 `deleteBook` 全按本机键走，下游零特判；原键本机不在库，本来就不出候选。
/// 本机同时有同键原生行（自己也加过同一部）时不追加，免得一条删除弹两次。
void aliasAdoptedInterconnectMangaTombstones(
  DeletionTombstoneEntries remoteTombstones,
  DeletionPresentEntries localPresent,
) {
  final String kind = SyncTombstoneKind.book.dbValue;
  final Map<String, int>? remoteBooks = remoteTombstones[kind];
  final Map<String, int?>? presentBooks = localPresent[kind];
  if (remoteBooks == null || presentBooks == null) return;
  final Map<String, int> aliases = <String, int>{};
  remoteBooks.forEach((String peerKey, int deletedAt) {
    if (presentBooks.containsKey(peerKey)) return;
    final String localKey = InterconnectMangaCatalog.localBookKeyFor(peerKey);
    if (!presentBooks.containsKey(localKey)) return;
    final int? prev = remoteBooks[localKey] ?? aliases[localKey];
    if (prev == null || deletedAt > prev) aliases[localKey] = deletedAt;
  });
  remoteBooks.addAll(aliases);
}
