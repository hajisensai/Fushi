import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/collection_book_identity_index.dart';

/// 目录占位与下载入库共用的主合集收养入口。
///
/// 只采纳 DTO 携带的主合集；完整同步仍负责多合集、删除与标签。DAO 在事务中
/// 裁决墓碑、自然键和排序，不把自动收养当成用户撤销删除。
class RemoteCollectionAdoptionService {
  const RemoteCollectionAdoptionService(this.database);

  final FushiDatabase database;

  Future<void> adoptVideo(RemoteVideoInfo video) => adoptMembership(
    membership: video.collection,
    mediaType: MediaKind.video,
    remoteEntryKey: video.id,
    localEntryKey: video.id,
  );

  /// 目录刷新：整份远端清单一次收养。身份索引只装载一次（全表读
  /// `epub_books` + alias），不按本数重复物化——dashboard 启动路径也走这里。
  Future<void> adoptBooks(Iterable<RemoteBookInfo> books) async {
    CollectionBookIdentityIndex? identities;
    for (final RemoteBookInfo book in books) {
      if (book.collection == null) continue;
      identities ??= await CollectionBookIdentityIndex.load(database);
      await adoptBook(book, identities: identities);
    }
  }

  /// [localBook] 必须是 importer/add 实际返回或按返回键重新读取的入库行。
  /// 目录刷新未提供时按 [identities]（未给则现装）从数据库解析，因而也能修复
  /// 历史已下载但无合集的孤儿。
  Future<void> adoptBook(
    RemoteBookInfo book, {
    EpubBookRow? localBook,
    CollectionBookIdentityIndex? identities,
  }) => database.transaction(() async {
    // 别名不再只限合集成员：下载落地键与对端键不同（对端同名书带 `(2)` 后缀、
    // EPUB 无 dc:title 时回落到临时文件名…）时，删除墓碑 / 标签也要靠它把两端
    // 认成同一本（BUG-3443 同类）。只有下载入库那一刻（[localBook] 是 importer
    // 的实际返回）能可靠建立这条对应，事后按对端键反查恰恰查不到。
    if (book.collection == null && localBook == null) return;
    final String key = book.downloadId;
    final EpubBookRow? local =
        localBook ?? await _findLocalBook(key, identities);
    if (local != null && local.bookKey != key) {
      await database.setCollectionBookAlias(local.uid, key);
      // 下载入库 = 这本书重新回到本机：撤销此前对它的「从所有设备删除」。那次
      // 墓碑写的是对端键（[FushiDatabase.syncDeletionBookKeyOf]），而
      // insertEpubBook 只按本机落地键清——不补清，还没推出去的那条会在下一轮
      // 推给 host，把刚重新下载的书从 host 删掉。目录刷新（localBook 为 null）
      // 不算重新入库，不碰墓碑。
      if (localBook != null) {
        await database.clearSyncDeletionTombstone(
          SyncTombstoneKind.book.dbValue,
          key,
        );
      }
    }
    if (book.collection == null) return;
    await adoptMembership(
      membership: book.collection,
      mediaType: MediaKind.epub,
      remoteEntryKey: key,
      localEntryKey: local?.uid,
    );
  });

  Future<EpubBookRow?> _findLocalBook(
    String remoteKey,
    CollectionBookIdentityIndex? preloaded,
  ) async {
    final CollectionBookIdentityIndex identities =
        preloaded ?? await CollectionBookIdentityIndex.load(database);
    final String? uid = identities.uidByKey[remoteKey];
    if (uid != null) return database.getEpubBookByUid(uid);
    if (preloaded == null) return null;
    // BUG-3452：[preloaded] 是整份清单收养开始时的快照，逐本收养之间别的事务照常
    // 落库——这一轮循环期间正好下载落地、已把占位成员提升成本地 uid 的书，在快照里
    // 查不到，按「本机没有」处理就会把对端键的占位成员行重新插回合集：合集里同一本
    // 书两行（本地卡 + 未下载占位卡，册数翻倍），直到下一轮目录刷新才被收掉。快照
    // 落空时在本事务里按对端键再精确查一次（本机落地键 = 对端键，或下载时记下的
    // 别名），只多两次按键查询，不重新物化整份索引。
    final EpubBookRow? sameKey = await database.getEpubBook(remoteKey);
    if (sameKey != null) return sameKey;
    final CollectionBookAliasRow? alias =
        await (database.select(database.collectionBookAliases)..where(
              ($CollectionBookAliasesTable t) => t.remoteKey.equals(remoteKey),
            ))
            .getSingleOrNull();
    return alias == null ? null : database.getEpubBookByUid(alias.localUid);
  }

  /// 适配器已经持有入库行和 DTO 归属时使用；无归属是纯 no-op。
  Future<void> adoptMembership({
    required RemoteCollectionMembership? membership,
    required MediaKind mediaType,
    required String remoteEntryKey,
    String? localEntryKey,
  }) async {
    if (membership == null) return;
    await database.adoptRemoteCollectionMember(
      name: membership.collectionName,
      collectionType: membership.collectionType,
      mediaType: mediaType,
      remoteEntryKey: remoteEntryKey,
      sortIndex: membership.sortIndex,
      localEntryKey: localEntryKey,
    );
  }
}
