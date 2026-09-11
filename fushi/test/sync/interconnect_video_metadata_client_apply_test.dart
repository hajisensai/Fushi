import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_locked_fields.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_work_loader.dart';
import 'package:fushi_engine/sync/video_metadata_manifest.dart';
import 'package:fushi_engine/sync/video_metadata_work_target.dart';

/// 7c 客户端落库：`applyRemoteVideoMetadata` 的目标解析 / 新旧判定 / 本地字段锁。
void main() {
  late FushiDatabase db;
  late int collectionId;

  VideoMetadataWorkEntry entry({
    String plot = 'host plot',
    int updatedAt = 1000,
    VideoMetadataWorkKey key = const VideoMetadataWorkKey.collection(
      name: 'Show',
      collectionType: 'collection',
    ),
  }) =>
      VideoMetadataWorkEntry(
        key: key,
        updatedAt: updatedAt,
        lockedFields: const <String>[],
        lookup: const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.mal,
          externalId: '7',
          mediaKind: VideoMetadataMediaKind.tv,
        ),
        work: VideoMetadataWork(
          provider: VideoMetadataProviderKind.mal,
          kind: VideoMetadataMediaKind.tv,
          title: 'Show',
          plot: plot,
          // 故意不带 id：wire 上 lookup 才是身份真相，apply 前须补齐。
        ),
      );

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    // 客户端典型形态：合集经清单同步建出来，成员一个在本机、一个只在 host。
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value<String>('Show S01E01'),
      title: Value<String>('Show S01E01'),
      videoPath: Value<String>('D:/dl/Show S01E01.mkv'),
    ));
    collectionId =
        await db.createMediaCollection('Show', collectionType: 'collection');
    await db.addToCollection(collectionId, MediaKind.video, 'Show S01E01');
    await db.addToCollection(collectionId, MediaKind.video, 'Show S01E02');
  });

  tearDown(() => db.close());

  test('合集在本机 → 落作品行并带上 host 主身份；只在 host 的成员不阻断', () async {
    final RemoteVideoMetadataApplyResult applied =
        await applyRemoteVideoMetadata(
      db,
      <VideoMetadataWorkEntry>[entry()],
    );
    expect(applied.applied, 1);
    final VideoMetadataWorkRow row =
        (await db.getVideoMetadataWorkByCollection(collectionId))!;
    expect(row.overview, 'host plot');
    final VideoMetadataLookup? lookup = await lookupOfWork(db, row.id);
    expect(lookup?.provider, VideoMetadataProviderKind.mal);
    expect(lookup?.externalId, '7');
  });

  test('本地作品行不比 host 旧则跳过（不重放旧数据）', () async {
    await applyRemoteVideoMetadata(db, <VideoMetadataWorkEntry>[entry()]);
    final VideoMetadataWorkRow local =
        (await db.getVideoMetadataWorkByCollection(collectionId))!;
    // host 的 updatedAt 比本地落库时刻早：跳过。
    final RemoteVideoMetadataApplyResult skipped =
        await applyRemoteVideoMetadata(
      db,
      <VideoMetadataWorkEntry>[
        entry(plot: 'stale', updatedAt: local.updatedAt - 1),
      ],
    );
    expect(skipped.applied, 0);
    expect(
      (await db.getVideoMetadataWorkByCollection(collectionId))!.overview,
      'host plot',
    );
    // host 更新了：覆盖。
    final RemoteVideoMetadataApplyResult fresh = await applyRemoteVideoMetadata(
      db,
      <VideoMetadataWorkEntry>[
        entry(plot: 'newer', updatedAt: local.updatedAt + 1),
      ],
    );
    expect(fresh.applied, 1);
    expect(
      (await db.getVideoMetadataWorkByCollection(collectionId))!.overview,
      'newer',
    );
  });

  test('本机没有的合集 / 单条目跳过，不抛', () async {
    final RemoteVideoMetadataApplyResult applied =
        await applyRemoteVideoMetadata(
      db,
      <VideoMetadataWorkEntry>[
        entry(
          key: const VideoMetadataWorkKey.collection(
            name: 'Elsewhere',
            collectionType: 'collection',
          ),
        ),
        entry(key: const VideoMetadataWorkKey.book('not-downloaded')),
      ],
    );
    expect(applied.applied, 0);
    expect(applied.deferred, 2, reason: '目标缺失计入 deferred，基线不得推进');
  });

  test('客户端自己锁的字段不被 host 覆盖', () async {
    await applyRemoteVideoMetadata(db, <VideoMetadataWorkEntry>[entry()]);
    final VideoMetadataWorkRow local =
        (await db.getVideoMetadataWorkByCollection(collectionId))!;
    await db.setVideoMetadataWorkLockedFields(
      local.id,
      encodeLockedFields(<VideoMetadataLockableField>{
        VideoMetadataLockableField.overview,
      }),
    );
    await applyRemoteVideoMetadata(
      db,
      <VideoMetadataWorkEntry>[
        entry(plot: 'host overwrite', updatedAt: local.updatedAt + 1),
      ],
    );
    expect(
      (await db.getVideoMetadataWorkByCollection(collectionId))!.overview,
      'host plot',
    );
  });
}
