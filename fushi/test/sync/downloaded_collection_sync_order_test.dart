import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/download/downloaded_collection_order.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart' show PlaylistEntry;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';

/// BUG-2941：下载合集逐集落库 + 每集之间跑一轮合集同步时，选集顺序必须是集号序。
///
/// 原路径：每集落库后 `reorderDownloadedCollectionEpisodes` 把本机排成集号序，但它
/// （刻意）不动 orderUpdatedAt；下一轮同步两端都为 0 → 平手取远端 → 远端上轮的
/// 到达序整表覆盖本机、新集追加末尾。逐集重复就得到用户截图里的
/// E06,02,01,10,05… 完成顺序。
const String _show = 'Grow Up Show (2026)';

String _uid(int episode) =>
    'video/$_show - S01E${episode.toString().padLeft(2, '0')}';

class _Device {
  _Device(this.db) : repo = VideoBookRepository(db);

  final FushiDatabase db;
  final VideoBookRepository repo;
  int baseline = 0;

  /// 下载管线导入阶段的同一组调用：导入一集 → 按集号整理。
  Future<int> landEpisode(int episode) async {
    final SplitPlaylistImportResult result = await repo.importSplitPlaylist(
      collectionName: _show,
      entries: <PlaylistEntry>[
        PlaylistEntry(
          title: 'Episode $episode',
          path:
              'D:/video/$_show/Season 01/'
              '$_show - S01E${episode.toString().padLeft(2, '0')}.mkv',
        ),
      ],
      reuseExistingPaths: true,
    );
    await repo.reorderDownloadedCollectionEpisodes(result.collectionId);
    return result.collectionId;
  }

  Future<List<String>> order() async {
    final MediaCollectionRow? row = await db.getMediaCollectionByNaturalKey(
      _show,
      'playlist',
    );
    if (row == null) return const <String>[];
    return <String>[
      for (final MediaCollectionItemRow item in await db.getCollectionItems(
        row.id,
      ))
        item.entryKey,
    ];
  }
}

class _Cloud {
  CollectionManifest manifest = const CollectionManifest(
    collections: <CollectionManifestEntry>[],
  );

  /// 编排器的读-合并-应用-写一轮。[derive] = false 复现修复前（不给派生序）。
  Future<void> sync(_Device device, {bool derive = true}) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
      local: await loadLocalCollectionManifest(device.db),
      remote: manifest,
      lastSyncedAtMs: device.baseline,
      nowMs: now,
      derivedOrder: derive
          ? await loadDownloadedCollectionDerivedOrder(device.db)
          : null,
    );
    await applyCollectionLocalChanges(device.db, outcome.changes);
    manifest = outcome.merged;
    device.baseline = now;
  }

  List<String> order() {
    final CollectionManifestEntry entry = manifest.collections.singleWhere(
      (CollectionManifestEntry e) => e.name == _show,
    );
    return <String>[
      for (final CollectionManifestMember m in entry.members) m.entryKey,
    ];
  }
}

Future<void> _markDownloadManaged(FushiDatabase db, int collectionId) =>
    db.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: 'job-$collectionId',
        resourceProvider: 'nyaa',
        selectedResourceId: 'resource',
        mediaKind: 'tv',
        title: 'Grow Up Show',
        backendKind: 'embedded',
        fingerprint: 'embedded/default',
        collectionId: Value<int?>(collectionId),
        createdAt: 1,
        updatedAt: 1,
      ),
    );

/// 用户实际的下载完成顺序。
const List<int> _arrival = <int>[6, 2, 1, 10, 5, 3];

void main() {
  late _Device pc;
  late _Device phone;
  late _Cloud cloud;

  setUp(() {
    pc = _Device(FushiDatabase.forTesting(NativeDatabase.memory()));
    phone = _Device(FushiDatabase.forTesting(NativeDatabase.memory()));
    cloud = _Cloud();
    addTearDown(() async {
      await pc.db.close();
      await phone.db.close();
    });
  });

  Future<void> downloadAll({required bool derive}) async {
    for (final int episode in _arrival) {
      final int collectionId = await pc.landEpisode(episode);
      await _markDownloadManaged(pc.db, collectionId);
      await cloud.sync(pc, derive: derive);
      await cloud.sync(phone, derive: derive);
    }
  }

  final List<String> episodeOrder = <String>[
    for (final int e in <int>[1, 2, 3, 5, 6, 10]) _uid(e),
  ];

  test('复现：不给派生序时，同步把集号序冲回下载完成顺序', () async {
    await downloadAll(derive: false);
    expect(await pc.order(), <String>[
      for (final int e in _arrival) _uid(e),
    ], reason: '这是修复前的真实落库形态（用户截图）');
  });

  test('逐集下载 + 每集之间同步：本机、对端、共享清单都收敛到集号序', () async {
    await downloadAll(derive: true);
    expect(await pc.order(), episodeOrder);
    expect(await phone.order(), episodeOrder);
    expect(cloud.order(), episodeOrder);
    expect(
      (await pc.db.getMediaCollectionByNaturalKey(
        _show,
        'playlist',
      ))!.orderUpdatedAt,
      0,
      reason: '派生序不能伪装成用户手动排序',
    );
  });

  test('收敛后再同步不再改写本地（无来回翻转）', () async {
    await downloadAll(derive: true);
    final CollectionSyncOutcome again = CollectionSyncEngine.merge(
      local: await loadLocalCollectionManifest(pc.db),
      remote: cloud.manifest,
      lastSyncedAtMs: pc.baseline,
      derivedOrder: await loadDownloadedCollectionDerivedOrder(pc.db),
    );
    expect(again.changes.isEmpty, isTrue);
  });

  test('有人手动排过序（orderUpdatedAt > 0）时手动序胜，派生序不介入', () async {
    await downloadAll(derive: true);
    final MediaCollectionRow row = (await phone.db
        .getMediaCollectionByNaturalKey(_show, 'playlist'))!;
    final List<String> manual = episodeOrder.reversed.toList();
    await phone.db.reorderCollectionItems(row.id, <CollectionMemberKey>[
      for (final String key in manual) (mediaType: 'video', entryKey: key),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await cloud.sync(phone);
    await cloud.sync(pc);
    expect(await pc.order(), manual);
  });

  test('非下载合集平手照旧取远端（派生序只认下载管理的合集）', () async {
    final int id = await pc.db.createMediaCollection(
      _show,
      collectionType: 'playlist',
    );
    for (final int e in _arrival) {
      await pc.db.addToCollection(id, MediaKind.video, _uid(e));
    }
    await cloud.sync(pc);
    expect(await pc.order(), <String>[for (final int e in _arrival) _uid(e)]);
  });
}
