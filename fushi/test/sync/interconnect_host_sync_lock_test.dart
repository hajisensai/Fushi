import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_state_apply_lock.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';

/// BUG-2717：本机当互联 host 时，对端的聚合 PUT / 合集 POST 不得排在本机整轮
/// 自动同步（`runExclusiveWithSync`）后面；但仍须与本机出站同步的本地落库步骤
/// 互斥（`runExclusiveWithSyncStateApply`），不能丢更新。
///
/// host 服务按 app 的生产接线构造（app_model.dart 的 libraryServiceFactory），
/// 并有一条源码守卫钉住那处接线。

const Duration _prompt = Duration(seconds: 30);

LocalLibraryHostService _appWiredHost(FushiDatabase db) =>
    LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory.systemTemp,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: runExclusiveWithSync,
      runSyncStateExclusive: runExclusiveWithSyncStateApply,
    );

AggregateSnapshot _readingSnapshot(int chars) => AggregateSnapshot(
  readingStats: <ReadingStatRecord>[
    ReadingStatRecord(
      title: 'Book A',
      dateKey: '2026-09-26',
      charactersRead: chars,
      readingTimeMs: chars * 10,
      lastStatisticModified: chars,
    ),
  ],
);

Future<int> _localChars(FushiDatabase db) async {
  final AggregateSnapshot snap = await AggregateSyncService(
    db,
  ).materializeLocalSnapshot();
  return snap.readingStats
      .where((ReadingStatRecord r) => r.title == 'Book A')
      .map((ReadingStatRecord r) => r.charactersRead)
      .fold<int>(0, (int a, int b) => a > b ? a : b);
}

const CollectionManifest _pushedManifest = CollectionManifest(
  collections: <CollectionManifestEntry>[
    CollectionManifestEntry(
      name: 'T',
      collectionType: 'collection',
      members: <CollectionManifestMember>[
        CollectionManifestMember(
          mediaType: 'epub',
          entryKey: 't1',
          sortIndex: 0,
        ),
      ],
    ),
  ],
);

/// 占住一把锁直到 [release] 完成；返回「已拿到锁」的 future。
Future<void> _holdLock(
  Future<void> Function(Future<void> Function() body) lock,
  Completer<void> release,
) {
  final Completer<void> acquired = Completer<void>();
  unawaited(
    lock(() async {
      acquired.complete();
      await release.future;
    }),
  );
  return acquired.future;
}

/// 进度 / 位置 PUT 的存在性闸门要求 host 已有该条目：书、视频、有声书各一行。
Future<void> _seedProgressTargets(FushiDatabase db) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: 'book-a',
      title: 'book-a',
      epubPath: '/tmp/book-a.epub',
      extractDir: '/tmp/book-a',
      chapterCount: 3,
      chaptersJson: '["ch1","ch2","ch3"]',
      importedAt: 1700000000000,
    ),
  );
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: 'video/a',
      title: 'Video A',
      videoPath: '/tmp/video-a.mp4',
    ),
  );
  await db.upsertAudiobook(
    AudiobooksCompanion.insert(
      bookKey: 'book-a',
      alignmentFormat: 'srt',
      alignmentPath: '/tmp/book-a.srt',
    ),
  );
}

/// 三条对端进度 / 位置写（时间戳取当前时刻之前，避开 BUG-3367 的未来戳截断）。
Map<String, Future<void> Function(LocalLibraryHostService host)> _progressPuts(
  int at,
) => <String, Future<void> Function(LocalLibraryHostService host)>{
  'book progress': (LocalLibraryHostService host) => host.putBookProgress(
    'book-a',
    RemoteBookProgress(
      sectionIndex: 2,
      normCharOffset: 8700,
      charOffset: 87,
      updatedAtMs: at,
    ),
  ),
  'video position': (LocalLibraryHostService host) =>
      host.putVideoPosition('video/a', 125000, at),
  'audiobook position': (LocalLibraryHostService host) =>
      host.putAudiobookPosition('book-a', 64000, at),
};

Future<bool> _progressLanded(
  LocalLibraryHostService host,
  String name,
  int at,
) async {
  switch (name) {
    case 'book progress':
      final RemoteBookProgress p = await host.getBookProgress('book-a');
      return p.normCharOffset == 8700 && p.updatedAtMs == at;
    case 'video position':
      return (await host.getVideoPosition('video/a')).positionMs == 125000;
    case 'audiobook position':
      return (await host.getAudiobookPosition('book-a')).positionMs == 64000;
  }
  throw ArgumentError(name);
}

void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('对端写不等 host 自己的整轮同步', () {
    test('整轮同步锁被占住时，对端聚合 PUT 立即落库', () async {
      final Completer<void> release = Completer<void>();
      await _holdLock(runExclusiveWithSync, release);
      try {
        await _appWiredHost(
          db,
        ).applyAggregateSnapshot(_readingSnapshot(300)).timeout(_prompt);
        expect(await _localChars(db), 300);
      } finally {
        release.complete();
      }
    });

    test('整轮同步锁被占住时，对端合集 POST 立即并入', () async {
      final Completer<void> release = Completer<void>();
      await _holdLock(runExclusiveWithSync, release);
      try {
        final CollectionManifest merged = await _appWiredHost(
          db,
        ).mergeCollectionManifest(_pushedManifest).timeout(_prompt);
        expect(
          merged.collections.map((CollectionManifestEntry e) => e.name),
          contains('T'),
        );
      } finally {
        release.complete();
      }
    });

    test('本机出站聚合同步卡在网络上时（持整轮锁），对端 PUT 不被窄锁挡住', () async {
      final Completer<Object?> network = Completer<Object?>();
      final Completer<void> fetchStarted = Completer<void>();
      // 按生产形状：出站同步整轮持 runExclusiveWithSync，本地落库步骤持窄锁。
      final Future<void> outbound = runExclusiveWithSync(() async {
        await AggregateSyncService(
          db,
          localApplyLock: runExclusiveWithSyncStateApply,
        ).syncOverClient(
          fetchRemote: () {
            fetchStarted.complete();
            return network.future;
          },
          pushMerged: (Object json) async {},
        );
      });
      await fetchStarted.future;
      try {
        await _appWiredHost(
          db,
        ).applyAggregateSnapshot(_readingSnapshot(300)).timeout(_prompt);
      } finally {
        network.complete(null);
        await outbound;
      }
      expect(await _localChars(db), 300);
    });
  });

  group('对端进度 / 位置 PUT 不等 host 自己的整轮同步', () {
    // 手机推进度 → 电脑正跑一轮自动同步（含云备份）→ PUT 排在整轮锁后面，手机
    // 15s 判超时；电脑放锁后照样落库，手机却没记下「已对齐」，下一轮误报冲突。
    final int at = DateTime.now().millisecondsSinceEpoch - 60000;
    for (final MapEntry<String, Future<void> Function(LocalLibraryHostService)>
        put
        in _progressPuts(at).entries) {
      test('整轮同步锁被占住时，${put.key} PUT 立即落库', () async {
        await _seedProgressTargets(db);
        final LocalLibraryHostService host = _appWiredHost(db);
        final Completer<void> release = Completer<void>();
        await _holdLock(runExclusiveWithSync, release);
        try {
          await put.value(host).timeout(_prompt);
          expect(await _progressLanded(host, put.key, at), isTrue);
        } finally {
          release.complete();
        }
      });

      test('窄锁被本地落库占住时，${put.key} PUT 等它放锁再写', () async {
        await _seedProgressTargets(db);
        final LocalLibraryHostService host = _appWiredHost(db);
        final Completer<void> release = Completer<void>();
        await _holdLock(runExclusiveWithSyncStateApply, release);
        bool done = false;
        final Future<void> write = put.value(host).then((_) => done = true);
        try {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(done, isFalse, reason: '读-比较-写必须整段在窄锁内');
        } finally {
          // 窄锁是进程级单例：断言失败也得放锁，否则后续用例全被连带卡死。
          release.complete();
        }
        await write.timeout(_prompt);
        expect(await _progressLanded(host, put.key, at), isTrue);
      });
    }
  });

  group('对端写与本机落库仍互斥、不丢更新', () {
    test('窄锁被本地落库占住时，对端聚合 PUT 等它放锁再写', () async {
      final Completer<void> release = Completer<void>();
      await _holdLock(runExclusiveWithSyncStateApply, release);
      bool done = false;
      final Future<void> put = _appWiredHost(
        db,
      ).applyAggregateSnapshot(_readingSnapshot(300)).then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(done, isFalse, reason: '窄锁未放，对端折叠不得与本地落库交错');
      release.complete();
      await put.timeout(_prompt);
      expect(await _localChars(db), 300);
    });

    test('窄锁被本地落库占住时，对端合集 POST 等它放锁再合并', () async {
      final Completer<void> release = Completer<void>();
      await _holdLock(runExclusiveWithSyncStateApply, release);
      bool done = false;
      final Future<void> post = _appWiredHost(
        db,
      ).mergeCollectionManifest(_pushedManifest).then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(done, isFalse);
      release.complete();
      await post.timeout(_prompt);
    });

    test('出站同步网络往返期间对端折进更大值 → 落库不被陈旧 merged 覆盖', () async {
      await AggregateSyncService(
        db,
      ).applySnapshotToLocal(_readingSnapshot(100));
      // 本机另有一条 host 没有的挖矿计数：保证合并结果与 host 不同、上行照常
      // 发生（内容相同会跳过 PUT），下面才能确认出站同步走完了上行这一步。
      await db.setMiningCount(
        sourceType: 'book',
        dateKey: '2026-06-02',
        count: 4,
      );

      final Completer<Object?> network = Completer<Object?>();
      final Completer<void> fetchStarted = Completer<void>();
      Object? pushed;
      final Future<void> outbound =
          AggregateSyncService(
            db,
            localApplyLock: runExclusiveWithSyncStateApply,
          ).syncOverClient(
            fetchRemote: () {
              fetchStarted.complete();
              return network.future;
            },
            pushMerged: (Object json) async => pushed = json,
          );
      // 出站同步已 materialize 本地（100），卡在拉远端。
      await fetchStarted.future;
      // 这期间对端经 host PUT 折进 500。
      await _appWiredHost(db).applyAggregateSnapshot(_readingSnapshot(500));
      expect(await _localChars(db), 500);
      // 远端回来的是 200：merged 基于陈旧的本地 100 → 200。旧实现直接写回 merged
      // 会把 500 覆盖成 200。
      network.complete(_readingSnapshot(200).toJson());
      await outbound.timeout(_prompt);

      expect(await _localChars(db), 500, reason: '统计只增不减：对端折进的值不得丢失');
      expect(pushed, isNotNull);
      expect(
        AggregateSnapshot.fromJson(
          pushed,
        ).miningStats.map((MiningRecord r) => r.dateKey),
        contains('2026-06-02'),
      );
    });
  });

  test('互联小请求超时消息带方法与路径、不带 query', () {
    final String msg = interconnectRequestTimeoutMessage(
      'PUT',
      Uri.parse('https://192.168.1.2:8765/api/library/aggregate?token=secret'),
      const Duration(seconds: 15),
    );
    expect(msg, contains('PUT /api/library/aggregate'));
    expect(msg, contains('interconnect request timed out'));
    expect(msg, isNot(contains('secret')));
  });

  group('源码守卫', () {
    test('app 的 host 库服务把同步状态域接到窄锁上', () {
      final String src = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      expect(
        src,
        contains('runSyncStateExclusive: runExclusiveWithSyncStateApply'),
        reason: '否则对端聚合 / 合集写会退回整轮同步锁，重现 15s 超时',
      );
    });

    test('出站同步的聚合 / 合集落库都持窄锁', () {
      final String aggregate = File(
        'lib/src/sync/sync_orchestrator/aggregate.part.dart',
      ).readAsStringSync();
      expect(
        'localApplyLock: runExclusiveWithSyncStateApply'
            .allMatches(aggregate)
            .length,
        2,
        reason: '云通道 sync() 与互联 syncOverClient() 两处都要接锁',
      );
      for (final String path in <String>[
        'lib/src/sync/sync_orchestrator.dart',
        'lib/src/sync/sync_orchestrator/collections.part.dart',
      ]) {
        final String src = File(path).readAsStringSync();
        // 容忍 dart format 把实参拆到下一行（`applyCollectionLocalChanges(\n  _db,`）。
        final int applyAt =
            RegExp(
              r'applyCollectionLocalChanges\(\s*_db',
            ).firstMatch(src)?.start ??
            -1;
        expect(applyAt, greaterThan(0), reason: path);
        final int lockAt = src.lastIndexOf(
          'runExclusiveWithSyncStateApply(',
          applyAt,
        );
        expect(lockAt, greaterThan(0), reason: '$path 的合集落库未持窄锁');
        expect(
          src.substring(lockAt, applyAt),
          isNot(contains('await _backend')),
          reason: '$path：窄锁内不得有网络调用',
        );
      }
    });
  });
}
