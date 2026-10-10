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

  /// 目录刷新：整份远端视频清单在**一个**事务里收养。
  ///
  /// 逐条 [adoptVideo] 是每条一个顶层事务、一次提交：几百条远端视频就是几百次
  /// 落盘提交。包进一个外层事务后，每条的 DAO 事务退化成保存点，整份清单只提交
  /// 一次。
  ///
  /// 注意变更通知**不会**因此合并：drift 的嵌套事务在保存点释放时就直接通知根
  /// 监听器，每条真写入仍各发一次合集表通知——合并靠消费端（库页的防抖重载）。
  /// 已收养过的条目在 DAO 里只读不写，整份清单都已收养时不产生任何通知。
  Future<void> adoptVideos(Iterable<RemoteVideoInfo> videos) =>
      database.transaction(() async {
        for (final RemoteVideoInfo video in videos) {
          await adoptVideo(video);
        }
      });

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
  }) =>
      database.transaction(() async {
        if (book.collection == null) return;
        final String key = book.downloadId;
        final EpubBookRow? local =
            localBook ?? await _findLocalBook(key, identities);
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

  Future<EpubBookRow?> _findLocalBook(
    String remoteKey,
    CollectionBookIdentityIndex? preloaded,
  ) async {
    final CollectionBookIdentityIndex identities =
        preloaded ?? await CollectionBookIdentityIndex.load(database);
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
