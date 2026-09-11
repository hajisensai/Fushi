/// 把互联 wire 上的作品自然键解析成 `VideoMetadataDatabaseStore.apply` 需要的本地
/// 作品单元，以及反方向（DB 作品行 → 自然键）。host（7a/7b）与客户端（7c）共用。
///
/// **不经计划器**：这里只回答「这个键在本机对应哪条合集行 / 哪些本地成员行」，不
/// 判断作品形态、不找来源库——所以 [VideoSourceScrapeWork.source] 为 null，只能喂
/// `apply`，不能喂 `scrapeSource`。真的要在本机刮（7a host 侧）走
/// `planScrapeWorksForCollection`。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataId, VideoMetadataWork;
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart'
    show VideoMetadataLookup;
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/sync/video_metadata_manifest.dart';

/// 自然键 → 本地作品单元；合集不存在 / 单条目不在库 → null。
///
/// 合集单元的成员只含**本机有行**的成员（客户端上「只在 host」的成员没有
/// `VideoBooks` 行，`apply` 对它们只写作品级与分季/分集行，不绑 bookUid）。
Future<VideoSourceScrapeWork?> resolveMetadataWorkTarget(
  FushiDatabase db,
  VideoMetadataWorkKey key,
) async {
  if (key.isCollection) {
    final MediaCollectionRow? collection =
        await db.getMediaCollectionByNaturalKey(
            key.collectionName!, key.collectionType!);
    if (collection == null) return null;
    final List<VideoBookRow> members = <VideoBookRow>[];
    for (final MediaCollectionItemRow item
        in await db.getCollectionItems(collection.id)) {
      if (item.mediaType != MediaKind.video.dbValue) continue;
      final VideoBookRow? row = await db.getVideoBookByBookUid(item.entryKey);
      if (row != null) members.add(row);
    }
    return VideoSourceScrapeWork(
      source: null,
      collection: collection,
      title: collection.name,
      members: members,
    );
  }
  final VideoBookRow? row = await db.getVideoBookByBookUid(key.bookUid!);
  if (row == null) return null;
  return VideoSourceScrapeWork(
    source: null,
    title: row.title,
    members: <VideoBookRow>[row],
  );
}

/// DB 作品行 → 自然键；合集行已不存在（悬空 collectionId）或作品既无合集也无
/// bookUid → null（这种行不上 wire）。
Future<VideoMetadataWorkKey?> metadataWorkKeyOf(
  FushiDatabase db,
  VideoMetadataWorkRow row,
) async {
  final int? collectionId = row.collectionId;
  if (collectionId != null) {
    final MediaCollectionRow? collection =
        await db.getMediaCollectionById(collectionId);
    if (collection == null) return null;
    return VideoMetadataWorkKey.collection(
      name: collection.name,
      collectionType: collection.collectionType,
    );
  }
  final String? bookUid = row.bookUid;
  if (bookUid == null || bookUid.isEmpty) return null;
  return VideoMetadataWorkKey.book(bookUid);
}

/// 让 [work] 的主身份与 [lookup] 一致：`apply` 按 `work.provider` 选主身份行、按
/// `work.ids` 写身份表，客户端送来的模型若缺这条 id（或 provider 不同）就补齐，
/// 否则 host 落库后 `confirmedLookup` 读不回客户端选定的身份。
VideoMetadataWork withLookupIdentity(
  VideoMetadataWork work,
  VideoMetadataLookup lookup,
) {
  final String type = lookup.provider.name;
  final bool hasId = work.ids.any(
    (VideoMetadataId id) =>
        id.type.toLowerCase() == type && id.value == lookup.externalId,
  );
  if (hasId && work.provider == lookup.provider) return work;
  return work.copyWith(
    provider: lookup.provider,
    ids: <VideoMetadataId>[
      if (!hasId) VideoMetadataId(type: type, value: lookup.externalId),
      ...work.ids,
    ],
  );
}

/// 7c 客户端侧：把 host 下发的作品条目落进本地 DB，返回实际写入条数。
///
/// 每条：解析本地目标（合集不在本机 / 单条目未下载 → 跳过）→ 本地已有作品行且
/// `updatedAt >= host.updatedAt` → 跳过（host 是刮削权威，但不重放旧数据）→
/// `VideoMetadataDatabaseStore.apply`（本地字段锁照旧保护用户在客户端锁的字段）。
/// 单条失败记日志不中断其余条目。
Future<int> applyRemoteVideoMetadata(
  FushiDatabase db,
  List<VideoMetadataWorkEntry> entries, {
  void Function(Object error, StackTrace stack)? onError,
}) async {
  final VideoMetadataDatabaseStore store = VideoMetadataDatabaseStore(db);
  int applied = 0;
  for (final VideoMetadataWorkEntry entry in entries) {
    try {
      final VideoSourceScrapeWork? target =
          await resolveMetadataWorkTarget(db, entry.key);
      if (target == null) continue;
      final VideoMetadataWorkRow? existing = target.collection == null
          ? await db.getVideoMetadataWorkByBook(target.members.single.bookUid)
          : await db.getVideoMetadataWorkByCollection(target.collection!.id);
      if (existing != null && existing.updatedAt >= entry.updatedAt) continue;
      final VideoMetadataLookup? lookup = entry.lookup;
      await store.apply(
        target,
        lookup == null ? entry.work : withLookupIdentity(entry.work, lookup),
      );
      applied += 1;
    } catch (e, stack) {
      onError?.call(e, stack);
    }
  }
  return applied;
}
