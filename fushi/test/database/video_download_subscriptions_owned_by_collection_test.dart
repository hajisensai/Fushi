import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (CommonDatabase rawDb) =>
          rawDb.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  addTearDown(db.close);
  return db;
}

VideoDownloadSubscriptionsCompanion _subscription(
  String id, {
  String? provider = 'mal',
  String? externalId,
  int? collectionId,
}) =>
    VideoDownloadSubscriptionsCompanion.insert(
      subscriptionId: id,
      resourceProvider: 'nyaa',
      metadataProvider: Value<String?>(provider),
      externalId: Value<String?>(provider == null ? null : externalId ?? id),
      mediaKind: 'tv',
      title: 'Show $id',
      searchQuery: 'Show $id',
      backendKind: 'embedded',
      fingerprint: 'embedded/default',
      collectionId: Value<int?>(collectionId),
      createdAt: 10,
      updatedAt: 10,
    );

VideoDownloadJobsCompanion _job(String id, {int? collectionId}) =>
    VideoDownloadJobsCompanion.insert(
      jobId: id,
      resourceProvider: 'nyaa',
      selectedResourceId: 'resource-$id',
      mediaKind: 'tv',
      title: 'Job $id',
      backendKind: 'embedded',
      fingerprint: 'embedded/default',
      collectionId: Value<int?>(collectionId),
      createdAt: 10,
      updatedAt: 10,
    );

Future<void> _linkItem(FushiDatabase db, String subscriptionId, String jobId) =>
    db.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: subscriptionId,
        logicalItemKey: 'S01E01',
        resourceProvider: 'nyaa',
        selectedResourceId: 'release-$jobId',
        title: 'Ep 1',
        jobId: Value<String?>(jobId),
        discoveredAt: 11,
        updatedAt: 11,
      ),
    );

/// 合集 [collectionId] 刮削到作品 `provider:externalId`。
Future<void> _scrapeWork(
  FushiDatabase db,
  int collectionId,
  String provider,
  String externalId,
) async {
  final int workId = await db.upsertVideoMetadataWork(
    VideoMetadataWorksCompanion.insert(
      collectionId: Value<int?>(collectionId),
      mediaType: 'tv',
      title: 'Work $externalId',
      updatedAt: 12,
    ),
  );
  await db.into(db.videoMetadataProviderIdentities).insert(
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'collection:$collectionId:$provider',
          workId: Value<int?>(workId),
          provider: provider,
          externalId: externalId,
          updatedAt: 12,
        ),
      );
}

Future<Set<String>> _owned(FushiDatabase db, List<int> ids) async => <String>{
      for (final VideoDownloadSubscriptionRow row
          in await db.getVideoDownloadSubscriptionsOwnedByCollections(ids))
        row.subscriptionId,
    };

void main() {
  test('三条归属线都能命中，其他合集与无身份订阅不被误中', () async {
    final FushiDatabase db = await _openDb();
    final int target = await db.createMediaCollection('Re:Zero S4');
    final int other = await db.createMediaCollection('Other');

    // 1. 订阅自己记着合集。
    await db.upsertVideoDownloadSubscription(
      _subscription('direct', collectionId: target),
    );
    // 2. 订阅派生的任务已整理进这个合集（订阅自己的 collection_id 为空——
    //    生产上的常态）。
    await db.upsertVideoDownloadSubscription(_subscription('via-job'));
    await db.upsertVideoDownloadJob(_job('job-1', collectionId: target));
    await _linkItem(db, 'via-job', 'job-1');
    // 3. 订阅的作品身份就是这个合集刮到的作品（大小写 / 空白归一）。
    await db.upsertVideoDownloadSubscription(
      _subscription('via-identity', provider: ' MAL ', externalId: ' 5114 '),
    );
    await _scrapeWork(db, target, 'mal', '5114');

    // 反例：别的合集的任务 / 身份、无身份订阅。
    await db.upsertVideoDownloadSubscription(_subscription('other-job'));
    await db.upsertVideoDownloadJob(_job('job-2', collectionId: other));
    await _linkItem(db, 'other-job', 'job-2');
    await db.upsertVideoDownloadSubscription(
      _subscription('other-identity', externalId: '9999'),
    );
    await _scrapeWork(db, other, 'mal', '9999');
    await db.upsertVideoDownloadSubscription(
      _subscription('no-identity', provider: null),
    );

    expect(
      await _owned(db, <int>[target]),
      <String>{'direct', 'via-job', 'via-identity'},
    );
    expect(await _owned(db, <int>[other]), <String>{'other-job', 'other-identity'});
    expect(await _owned(db, <int>[]), isEmpty);
  });

  test('删合集之后归属线断开——所以必须在删除前取快照', () async {
    final FushiDatabase db = await _openDb();
    final int target = await db.createMediaCollection('Show');
    await db.upsertVideoDownloadSubscription(_subscription('via-job'));
    await db.upsertVideoDownloadJob(_job('job-1', collectionId: target));
    await _linkItem(db, 'via-job', 'job-1');
    await db.upsertVideoDownloadSubscription(
      _subscription('via-identity', externalId: '42'),
    );
    await _scrapeWork(db, target, 'mal', '42');

    final Set<String> before = await _owned(db, <int>[target]);
    expect(before, <String>{'via-job', 'via-identity'});

    await db.deleteMediaCollection(target);
    expect(await _owned(db, <int>[target]), isEmpty);

    // 用删除前的快照删订阅：订阅行与 items 一起消失，任务本身保留。
    expect(await db.deleteVideoDownloadSubscriptions(before), 2);
    expect(await db.getVideoDownloadSubscription('via-job'), isNull);
    expect(await db.getVideoDownloadSubscription('via-identity'), isNull);
    expect(await db.getVideoDownloadJob('job-1'), isNotNull);
    expect(await db.deleteVideoDownloadSubscriptions(<String>[]), 0);
  });
}
