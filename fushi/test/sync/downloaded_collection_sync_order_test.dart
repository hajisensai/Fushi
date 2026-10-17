import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/download/downloaded_collection_order.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart' show PlaylistEntry;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';

/// BUG-2941：下载合集逐集落库 + 每集之间跑合集同步时，选集顺序必须是集号序。
///
/// 原路径：每集落库后 `reorderDownloadedCollectionEpisodes` 把本机排成集号序，但它
/// （刻意）不动 orderUpdatedAt；下一轮同步两端都为 0 → 平手取远端 → 远端上轮的
/// 到达序整表覆盖本机、新集追加末尾。逐集重复就得到用户截图里的
/// E06,02,01,10,05… 完成顺序。
///
/// 集号故意不补零（S01E1 / S01E2 / S01E10）：成员键字典序 ≠ 集号序，云通道折叠
/// 多份对端文件平手取「字典序最小」的那份时，没有下载任务的设备不能停在它上面。
const String _show = 'Grow Up Show (2026)';

String _uid(int episode) => 'video/$_show - S01E$episode';

/// 用户实际的下载完成顺序。
const List<int> _arrival = <int>[6, 2, 1, 10, 5, 3];
final List<String> _arrivalOrder = <String>[
  for (final int e in _arrival) _uid(e),
];
final List<String> _episodeOrder = <String>[
  for (final int e in <int>[1, 2, 3, 5, 6, 10]) _uid(e),
];

class _Device {
  _Device(this.id) : db = FushiDatabase.forTesting(NativeDatabase.memory()) {
    repo = VideoBookRepository(db);
  }

  final String id;
  final FushiDatabase db;
  late final VideoBookRepository repo;
  int baseline = 0;

  /// 下载管线导入阶段的同一组调用：导入一集 → 按集号整理 → 任务指向合集。
  Future<void> landEpisode(int episode, {bool downloadJob = true}) async {
    final SplitPlaylistImportResult result = await repo.importSplitPlaylist(
      collectionName: _show,
      entries: <PlaylistEntry>[
        PlaylistEntry(
          title: 'Episode $episode',
          path: 'D:/video/$_show/Season 01/$_show - S01E$episode.mkv',
        ),
      ],
      reuseExistingPaths: true,
    );
    await repo.reorderDownloadedCollectionEpisodes(result.collectionId);
    if (!downloadJob) return;
    await db.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: 'job-$episode',
        resourceProvider: 'nyaa',
        selectedResourceId: 'resource-$episode',
        mediaKind: 'tv',
        title: 'Grow Up Show',
        backendKind: 'embedded',
        fingerprint: 'embedded/default',
        collectionId: Value<int?>(result.collectionId),
        createdAt: 1,
        updatedAt: 1,
      ),
    );
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

  /// 一轮读-合并-应用；返回本端被改写的合集数。
  Future<int> mergeWith(
    CollectionManifest remote,
    void Function(CollectionManifest merged) publish,
  ) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
      local: await loadLocalCollectionManifest(db),
      remote: remote,
      lastSyncedAtMs: baseline,
      nowMs: now,
    );
    final int changed = await applyCollectionLocalChanges(db, outcome.changes);
    publish(outcome.merged.withLastWrittenAt(now));
    baseline = now;
    return changed;
  }
}

List<String> _orderIn(CollectionManifest manifest) {
  final CollectionManifestEntry entry = manifest.collections.singleWhere(
    (CollectionManifestEntry e) => e.name == _show,
  );
  final List<CollectionManifestMember> members =
      List<CollectionManifestMember>.of(entry.members)..sort(
        (CollectionManifestMember a, CollectionManifestMember b) =>
            a.sortIndex.compareTo(b.sortIndex),
      );
  return <String>[for (final CollectionManifestMember m in members) m.entryKey];
}

/// 单份共享清单（互联 live：client GET → merge → POST 回 host）。
class _SharedManifest {
  CollectionManifest manifest = const CollectionManifest(
    collections: <CollectionManifestEntry>[],
  );

  Future<int> sync(_Device d) =>
      d.mergeWith(manifest, (CollectionManifest m) => manifest = m);
}

/// 云通道：每台设备写自己的 per-device 文件，读时折叠全部文件（含自己上一轮的）。
class _PerDeviceCloud {
  final Map<String, CollectionManifest> files = <String, CollectionManifest>{};

  Future<int> sync(_Device d) => d.mergeWith(
    CollectionSyncEngine.combinePeers(files.values.toList()),
    (CollectionManifest m) => files[d.id] = m,
  );
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 3));

void main() {
  late _Device pc;
  late _Device phone;

  setUp(() {
    pc = _Device('pc');
    phone = _Device('phone');
    addTearDown(() async {
      await pc.db.close();
      await phone.db.close();
    });
  });

  test('前提：成员键解得出集号，且字典序与集号序不同', () {
    expect(parseVideoPath(_uid(10)).episode, 10);
    expect(parseVideoPath(_uid(10)).season, 1);
    expect(List<String>.of(_episodeOrder)..sort(), isNot(_episodeOrder));
  });

  group('单份共享清单（互联 live）', () {
    late _SharedManifest shared;
    setUp(() => shared = _SharedManifest());

    Future<void> downloadAll({bool downloadJob = true}) async {
      for (final int episode in _arrival) {
        await pc.landEpisode(episode, downloadJob: downloadJob);
        await shared.sync(pc);
        await shared.sync(phone);
        await _tick();
      }
    }

    test('复现：合集未被识别为下载合集时，同步把集号序冲回下载完成顺序', () async {
      await downloadAll(downloadJob: false);
      expect(await pc.order(), _arrivalOrder, reason: '修复前的真实落库形态（用户截图）');
    });

    test('逐集下载 + 每集之间同步：本机、对端、共享清单都收敛到集号序', () async {
      await downloadAll();
      expect(await pc.order(), _episodeOrder);
      expect(await phone.order(), _episodeOrder);
      expect(_orderIn(shared.manifest), _episodeOrder);
      expect(
        (await pc.db.getMediaCollectionByNaturalKey(
          _show,
          'playlist',
        ))!.orderUpdatedAt,
        0,
        reason: '集号序不能伪装成用户手动排序',
      );
    });

    test('收敛后再同步两端都零改写', () async {
      await downloadAll();
      expect(await shared.sync(pc), 0);
      expect(await shared.sync(phone), 0);
    });

    test('有人手动排过序时手动序胜，集号序不介入', () async {
      await downloadAll();
      final MediaCollectionRow row = (await phone.db
          .getMediaCollectionByNaturalKey(_show, 'playlist'))!;
      final List<String> manual = _episodeOrder.reversed.toList();
      await phone.db.reorderCollectionItems(row.id, <CollectionMemberKey>[
        for (final String key in manual) (mediaType: 'video', entryKey: key),
      ]);
      await _tick();
      await shared.sync(phone);
      await shared.sync(pc);
      expect(await pc.order(), manual);
    });
  });

  group('云通道 per-device 文件', () {
    test('没有下载任务的设备也收敛到集号序，不停在自己旧文件的字典序最小序上', () async {
      final _PerDeviceCloud cloud = _PerDeviceCloud();
      for (final int episode in _arrival) {
        await pc.landEpisode(episode);
        await cloud.sync(pc);
        await cloud.sync(phone);
        await _tick();
      }
      // 再跑两轮：对端旧文件（含 phone 自己的）都参与折叠。
      for (int round = 0; round < 2; round++) {
        await cloud.sync(phone);
        await cloud.sync(pc);
        await _tick();
      }
      expect(await pc.order(), _episodeOrder);
      expect(await phone.order(), _episodeOrder);
      for (final CollectionManifest file in cloud.files.values) {
        expect(_orderIn(file), _episodeOrder);
      }
      expect(await cloud.sync(phone), 0, reason: '收敛后零改写');
      expect(await cloud.sync(pc), 0, reason: '收敛后零改写');
    });
  });

  test('非下载合集平手照旧取远端（集号序只认下载管理的合集）', () async {
    final _SharedManifest shared = _SharedManifest();
    final int id = await pc.db.createMediaCollection(
      _show,
      collectionType: 'playlist',
    );
    for (final int e in _arrival) {
      await pc.db.addToCollection(id, MediaKind.video, _uid(e));
    }
    await shared.sync(pc);
    await shared.sync(phone);
    expect(await phone.order(), _arrivalOrder);
    expect(await pc.order(), _arrivalOrder);
  });

  test('集号序只动视频成员，非视频成员原位不动', () {
    final List<CollectionMemberKey> ordered =
        orderDownloadedCollectionMembers(<CollectionMemberKey>[
          (mediaType: 'video', entryKey: _uid(10)),
          (mediaType: 'epub', entryKey: 'book-a'),
          (mediaType: 'video', entryKey: 'video/$_show - PV'),
          (mediaType: 'video', entryKey: _uid(2)),
        ]);
    expect(ordered, <CollectionMemberKey>[
      (mediaType: 'video', entryKey: _uid(2)),
      (mediaType: 'epub', entryKey: 'book-a'),
      (mediaType: 'video', entryKey: _uid(10)),
      (mediaType: 'video', entryKey: 'video/$_show - PV'),
    ]);
  });

  test('云折叠：删除发布之前的旧文件不能把集号序标记带给同名重建的合集', () {
    CollectionManifest file(int writtenAt, CollectionManifestEntry e) =>
        CollectionManifest(
          collections: <CollectionManifestEntry>[e],
          lastWrittenAt: writtenAt,
        );
    const List<CollectionManifestMember> members = <CollectionManifestMember>[
      CollectionManifestMember(mediaType: 'video', entryKey: 'v', sortIndex: 0),
    ];
    // 离线设备的旧文件（t=10）：下载合集、带标记。
    final CollectionManifest stale = file(
      10,
      const CollectionManifestEntry(
        name: 'X',
        collectionType: 'playlist',
        members: members,
        episodeOrdered: true,
      ),
    );
    // t=20 发布删除；t=30 用户同名新建普通合集（无标记）。
    final CollectionManifest deleted = file(
      20,
      const CollectionManifestEntry(
        name: 'X',
        collectionType: 'playlist',
        deletedAt: 20,
        deletedPublishedAt: 20,
      ),
    );
    final CollectionManifest recreated = file(
      30,
      const CollectionManifestEntry(
        name: 'X',
        collectionType: 'playlist',
        members: members,
      ),
    );
    final CollectionManifestEntry folded = CollectionSyncEngine.combinePeers(
      <CollectionManifest>[stale, deleted, recreated],
    ).collections.single;
    expect(folded.deletedAt, isNull, reason: '删除后重建胜');
    expect(folded.episodeOrdered, isFalse);

    // 对照：没有删除时，任一文件带标记即是。
    expect(
      CollectionSyncEngine.combinePeers(<CollectionManifest>[
        stale,
        recreated,
      ]).collections.single.episodeOrdered,
      isTrue,
    );
  });

  test('本机落库整理认父目录上的季号（旧番剧种子导入保留原文件名）', () async {
    final _Device d = _Device('local');
    addTearDown(d.db.close);
    int? collectionId;
    for (final String path in <String>[
      'D:/anime/Show/Season 2/01.mkv',
      'D:/anime/Show/Season 1/02.mkv',
      'D:/anime/Show/Season 1/01.mkv',
    ]) {
      final SplitPlaylistImportResult result = await d.repo.importSplitPlaylist(
        collectionName: 'Show',
        entries: <PlaylistEntry>[PlaylistEntry(title: '', path: path)],
        reuseExistingPaths: true,
      );
      collectionId = result.collectionId;
    }
    await d.repo.reorderDownloadedCollectionEpisodes(collectionId!);
    final List<String> paths = <String>[
      for (final MediaCollectionItemRow item in await d.db.getCollectionItems(
        collectionId,
      ))
        (await d.db.getVideoBookByBookUid(item.entryKey))!.videoPath,
    ];
    expect(paths, <String>[
      'D:/anime/Show/Season 1/01.mkv',
      'D:/anime/Show/Season 1/02.mkv',
      'D:/anime/Show/Season 2/01.mkv',
    ]);
  });

  test('episodeOrdered 是 additive wire 字段：false 不写 key、旧清单读作 false', () {
    const CollectionManifestEntry plain = CollectionManifestEntry(
      name: 'A',
      collectionType: 'playlist',
    );
    expect(plain.toJson().containsKey('episodeOrdered'), isFalse);
    const CollectionManifestEntry flagged = CollectionManifestEntry(
      name: 'A',
      collectionType: 'playlist',
      episodeOrdered: true,
    );
    final Object? decoded = jsonDecode(jsonEncode(flagged.toJson()));
    expect(CollectionManifestEntry.fromJson(decoded).episodeOrdered, isTrue);
    expect(
      CollectionManifestEntry.fromJson(
        jsonDecode(jsonEncode(plain.toJson())),
      ).episodeOrdered,
      isFalse,
    );
  });
}
