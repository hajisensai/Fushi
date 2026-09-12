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

  /// [localBook] 必须是 importer/add 实际返回或按返回键重新读取的入库行。
  /// 目录刷新未提供时从数据库重新解析，因而也能修复历史已下载但无合集的孤儿。
  Future<void> adoptBook(RemoteBookInfo book, {EpubBookRow? localBook}) =>
      database.transaction(() async {
        if (book.collection == null) return;
        final String key = book.downloadId;
        final EpubBookRow? local = localBook ?? await _findLocalBook(key);
        if (local != null && local.bookKey != key) {
          await database.setCollectionBookAlias(local.uid, key);
        }
        await adoptMembership(
          membership: book.collection,
          mediaType: MediaKind.epub,
          remoteEntryKey: key,
          localEntryKey: local?.uid,
        );
      });

  Future<EpubBookRow?> _findLocalBook(String remoteKey) async {
    final CollectionBookIdentityIndex identities =
        await CollectionBookIdentityIndex.load(database);
    final String? uid = identities.uidByKey[remoteKey];
    return uid == null ? null : database.getEpubBookByUid(uid);
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
