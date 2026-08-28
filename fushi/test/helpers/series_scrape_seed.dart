import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

/// 给合集种一条 **AniDB 主身份**（规范作品身份 + 刮削标题）。
///
/// 🔴 BUG-1839 起这**不再是入墙资格**：「系列」页已不按刮削 provider 门控，零刮削
/// 的普通合集照样折成合集卡（用户拍板「合集就应该在系列里面」，契约见
/// `test/pages/home_video_series_admission_test.dart` 与
/// `test/pages/video_library_series_structure_guard_test.dart`）。
///
/// 保留本 helper 是因为调用点里有一批用例需要**刮削作品本身**（规范标题、
/// work 归属、封面借用链），种上它们才测得到自己真正要守的那层；新写用例若只是
/// 要一个能出现在系列墙上的合集，直接 `createMediaCollection` 即可，不必种身份。
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

/// 给独立视频种一条 AniDB 主身份（book-owned work）。
///
/// 与 [seedAniDbSeriesIdentity] 同理：BUG-1839 起散卡不种身份也照常进系列墙，
/// 这里只提供「有刮削作品身份的独立视频」这一形态。
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
/// 供需要「合集 + 刮削作品身份」两件事的测试一次种好。
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
