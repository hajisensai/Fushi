import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

/// 给合集种一条 **AniDB 主身份**，使它有资格出现在「系列」墙上。
///
/// 「系列」页的入墙资格不是「是个合集」，而是「有 AniDB primary identity 的规范
/// 作品」（`FushiDatabase.aniDbScrapedVideoCollectionIds()`，契约见
/// `test/pages/video_library_series_structure_guard_test.dart`）。
///
/// 大量库页 widget 测试拿「系列」当测试面，但它们守的是封面借用链、角标、批量选择、
/// 折叠与排序——不是入墙资格本身。不种身份的话这些用例会齐刷刷停在「合集卡根本
/// 没渲染」上，测不到它们真正要守的东西，而那恰恰是最容易被悄悄改坏的一层。
///
/// 只种身份，不碰断言：调用点该断言什么还断言什么。
Future<void> seedAniDbSeriesIdentity(
  FushiDatabase db,
  int collectionId, {
  String title = '某番剧',
  int updatedAt = 0,
}) async {
  final int workId = await db.upsertVideoMetadataWork(
    VideoMetadataWorksCompanion.insert(
      mediaType: 'tv',
      title: title,
      collectionId: Value<int?>(collectionId),
      updatedAt: updatedAt,
    ),
  );
  await db.replaceVideoMetadataProviderIdentities(
    workId: workId,
    identities: <VideoMetadataProviderIdentitiesCompanion>[
      VideoMetadataProviderIdentitiesCompanion.insert(
        identityKey: 'work:$workId:anidb',
        provider: 'anidb',
        externalId: 'anidb-$collectionId',
        isPrimary: const Value<bool>(true),
        updatedAt: updatedAt,
      ),
    ],
  );
}

/// 给**不属于任何已刮削合集的独立视频**种一条 AniDB 主身份（book-owned work）。
///
/// 与 [seedAniDbSeriesIdentity] 是同一条入墙资格的另一半：`_isAniDbScrapedSeriesMember`
/// 认「合集归属」或「book 自身身份」二者之一。测「散卡」行为（散卡与合集卡混排、
/// 仅散卡时的批量新建合集）时必须种这一条，否则散卡在系列页根本不渲染。
Future<void> seedAniDbLooseIdentity(
  FushiDatabase db,
  String bookUid, {
  String title = '独立视频',
  int updatedAt = 0,
}) async {
  final int workId = await db.upsertVideoMetadataWork(
    VideoMetadataWorksCompanion.insert(
      mediaType: 'movie',
      title: title,
      bookUid: Value<String?>(bookUid),
      updatedAt: updatedAt,
    ),
  );
  await db.replaceVideoMetadataProviderIdentities(
    workId: workId,
    identities: <VideoMetadataProviderIdentitiesCompanion>[
      VideoMetadataProviderIdentitiesCompanion.insert(
        identityKey: 'work:$workId:anidb',
        provider: 'anidb',
        externalId: 'anidb-$bookUid',
        isPrimary: const Value<bool>(true),
        updatedAt: updatedAt,
      ),
    ],
  );
}

/// [FushiDatabase.createMediaCollection] + [seedAniDbSeriesIdentity] 的组合，
/// 供「建完就该上系列墙」的测试直接替换原来的 createMediaCollection 调用。
Future<int> createSeriesCollection(
  FushiDatabase db,
  String name, {
  String collectionType = 'collection',
}) async {
  final int id = await db.createMediaCollection(
    name,
    collectionType: collectionType,
  );
  await seedAniDbSeriesIdentity(db, id, title: name);
  return id;
}
