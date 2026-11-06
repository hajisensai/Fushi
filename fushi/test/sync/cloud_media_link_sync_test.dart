import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi_core/fushi_core.dart';

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

/// 作品图谱云通道：`__collections__` 命名空间下 per-device 的
/// `media-links-<deviceId>.json`。两台设备共享同一份假云，连接 / 否决墓碑双向一致，
/// 对方的文件不被覆盖，合集清单的折叠不会误读作品图谱文件。
void main() {
  late Directory work;
  late FakeAssetStore store;
  late FushiDatabase dbA;
  late FushiDatabase dbB;
  late FakeSyncBackend backendA;
  late FakeSyncBackend backendB;

  SyncOrchestrator orch(FushiDatabase db, FakeSyncBackend backend, String id) =>
      SyncOrchestrator(
        db: db,
        backend: backend,
        dictionaryResourceRoot: work,
        audioDatabaseRoot: work,
        tempDir: work,
        deviceId: id,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncMangaContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
      );

  Future<SyncRunReport> syncA() async {
    final SyncRunReport r = SyncRunReport();
    await orch(dbA, backendA, 'devA').syncMediaLinksCloudForTest(r);
    return r;
  }

  Future<SyncRunReport> syncB() async {
    final SyncRunReport r = SyncRunReport();
    await orch(dbB, backendB, 'devB').syncMediaLinksCloudForTest(r);
    return r;
  }

  setUp(() async {
    work = await Directory.systemTemp.createTemp('ml_cloud_');
    store = FakeAssetStore();
    dbA = FushiDatabase.forTesting(NativeDatabase.memory());
    dbB = FushiDatabase.forTesting(NativeDatabase.memory());
    backendA = FakeSyncBackend(store);
    backendB = FakeSyncBackend(store);
    addTearDown(() async {
      await dbA.close();
      await dbB.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });
  });

  test('per-device 文件互不覆盖；连接与否决墓碑双向一致；空库不建空文件', () async {
    await syncA();
    expect(
      (await store.listChildren(kSyncCollectionsNamespace)).map((e) => e.name),
      isNot(contains('media-links-devA.json')),
      reason: '没有任何连接：不无中生有地发布空文件',
    );

    await dbA.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: (kind: MediaLinkKind.book, key: 'novel'),
      to: (kind: MediaLinkKind.videoEpisode, key: 'video/movie'),
      at: 10,
    );
    final SyncRunReport first = await syncA();
    expect(first.errors, isEmpty);
    await syncB();
    final List<MediaLinkRow> onB = await dbB.allMediaLinks();
    expect(onB, hasLength(1));
    expect(onB.single.isUserConfirmed, isTrue);

    await dbB.removeMediaLink(mediaLinkIdOf(onB.single), at: 20);
    await syncB();
    await syncA();
    expect(
      await dbA.mediaLinksForEndpoint(MediaLinkKind.book, 'novel'),
      isEmpty,
      reason: 'B 的墓碑经 B 自己那份文件到了 A',
    );
    expect(
      (await store.listChildren(kSyncCollectionsNamespace)).map((e) => e.name),
      containsAll(<String>['media-links-devA.json', 'media-links-devB.json']),
    );
    // 收敛后再同步：A 的文件内容已与本机一致，不回写也不复活。
    await syncA();
    await syncB();
    expect(
      await dbB.mediaLinksForEndpoint(MediaLinkKind.book, 'novel'),
      isEmpty,
    );
  });

  test('作品图谱文件名与合集清单文件名互斥', () {
    expect(isMediaLinksManifestName('media-links-devA.json'), isTrue);
    expect(isMediaLinksManifestName('media-links.json'), isTrue);
    expect(isCollectionsManifestName('media-links-devA.json'), isFalse);
    expect(isMediaLinksManifestName('collections-devA.json'), isFalse);
    expect(mediaLinksManifestNameFor(''), 'media-links.json');
  });
}
