import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/cloud_book_content_names.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_peer_snapshot_cache.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_engine/sync/ttu_models.dart';

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

// jHQpTfjrNB：「很久没看过的书为什么还要同步这么久」。
//
// 这里钉的是**同一份远端、什么都没变**时一轮同步要付的往返 / 写库次数——反馈里
// 慢的正是这种稳态：没有快照的后端（WebDAV / OneDrive / FTP / SFTP）每本书本该只
// 列一次文件夹，旧实现却为「补传书文件」再列一次、为「有声书包在不在」再 HEAD 1–2
// 次，每台设备的 per-device 清单每轮整份重下，未变的书每轮还重写一次同步基线。
//
// 计数即基准：断言写的是修后的预算，注释里给出修前的值。

/// 计数的内存数据库：数清同步基线写入与「整表读统计」的次数。
class _CountingDb extends FushiDatabase {
  _CountingDb() : super.forTesting(NativeDatabase.memory());

  int baselineWrites = 0;
  int fullStatsScans = 0;

  @override
  Future<void> setSyncBaseline(
    String assetKey,
    String dimension,
    int baseVersion,
  ) {
    baselineWrites++;
    return super.setSyncBaseline(assetKey, dimension, baseVersion);
  }

  @override
  Future<List<ReadingStatisticRow>> getAllReadingStatistics() {
    fullStatsScans++;
    return super.getAllReadingStatistics();
  }
}

/// 路径式、**无快照**的书文件夹后端（WebDAV / OneDrive / FTP / SFTP 的形状）：
/// `listSyncFiles` 与 `listChildren` 都是对同一个文件夹的一次整目录列举。
class _FolderBackend implements SyncBackend {
  /// folderId → 文件名 → 内容（JSON 文件存解码后的对象，内容文件存 null）。
  final Map<String, Map<String, Object?>> folders =
      <String, Map<String, Object?>>{};

  int listSyncFilesCalls = 0;
  int listChildrenCalls = 0;
  int contentProbes = 0;
  int contentUploads = 0;
  int jsonWrites = 0;
  final List<List<TtuStatistics>> statsUploads = <List<TtuStatistics>>[];

  String folderOf(String title) => 'root/${sanitizeTtuFilename(title)}/';

  @override
  Future<String> findOrCreateRootFolder() async => 'root/';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async {
    final String id = folderOf(bookTitle);
    folders.putIfAbsent(id, () => <String, Object?>{});
    _cache[sanitizeTtuFilename(bookTitle)] = id;
    return id;
  }

  /// 模拟一次网络往返的耗时（0 = 立即返回）。
  Duration listLatency = Duration.zero;
  int _inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    listSyncFilesCalls++;
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    try {
      if (listLatency > Duration.zero) await Future<void>.delayed(listLatency);
    } finally {
      _inFlight--;
    }
    return syncFileTrioFromFiles(<SyncFileRef>[
      for (final String name in folders[folderId]!.keys)
        SyncFileRef(id: '$folderId$name', name: name),
    ]);
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    listChildrenCalls++;
    return <AssetEntry>[
      for (final String name in folders[namespaceId]!.keys)
        AssetEntry(id: '$namespaceId$name', name: name),
    ];
  }

  @override
  Future<SyncFileRef?> findContentFile(String folderId, String fileName) async {
    contentProbes++;
    return folders[folderId]!.containsKey(fileName)
        ? SyncFileRef(id: '$folderId$fileName', name: fileName)
        : null;
  }

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    SyncTransferProgress? onProgress,
  }) async {
    contentUploads++;
    folders[folderId]![fileName] = null;
  }

  @override
  Future<void> putJsonAsset(
    String namespaceId,
    String name,
    Object? json,
  ) async {
    jsonWrites++;
    folders[namespaceId]![name] = json;
  }

  Object? _byId(String fileId) {
    final int slash = fileId.lastIndexOf('/');
    return folders[fileId.substring(0, slash + 1)]![fileId.substring(
      slash + 1,
    )];
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async =>
      _byId(fileId)! as TtuProgress;

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async =>
      const <TtuStatistics>[];

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    final Map<String, Object?> f = folders[folderId]!;
    f.removeWhere((String k, _) => k.startsWith('progress_'));
    f[progressFileName(progress.lastBookmarkModified, progress.progress)] =
        progress;
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    statsUploads.add(stats);
  }

  String? _root;
  final Map<String, String> _cache = <String, String>{};

  @override
  String? get cachedRootFolderId => _root;

  @override
  Map<String, String> get cachedFolderIds => _cache;

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    _root = rootFolderId ?? 'root/';
    if (titleToFolderId != null) _cache.addAll(titleToFolderId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

const String _chapters = '[{"title":"c1","characters":1000}]';

/// 一本「很久没看过」的书：本地进度、远端进度、同步基线三者是同一个时间戳，远端
/// 书文件夹里书文件早就传过了。
Future<void> _seedSettledBook(
  _CountingDb db,
  _FolderBackend backend,
  Directory work,
  String title,
) async {
  final Directory extract = Directory('${work.path}/$title')..createSync();
  File('${extract.path}/content.opf').writeAsStringSync('<package/>');
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: title,
      title: title,
      epubPath: '$title.epub',
      extractDir: extract.path,
      chapterCount: 1,
      chaptersJson: _chapters,
      importedAt: 1,
    ),
  );
  final String uid = (await db.resolveEpubBookUid(title))!;
  await db.upsertReaderPosition(
    ReaderPositionsCompanion(
      bookUid: Value<String>(uid),
      sectionIndex: const Value<int>(0),
      normCharOffset: const Value<int>(5000),
      updatedAt: const Value<int>(1000),
    ),
  );
  await db.setSyncBaseline(
    sanitizeTtuFilename(title),
    progressBaselineDimensionOf(backend),
    1000,
  );
  backend.folders[backend.folderOf(title)] = <String, Object?>{
    progressFileName(1000, 0.5): TtuProgress(
      dataId: 0,
      exploredCharCount: 500,
      progress: 0.5,
      lastBookmarkModified: 1000,
    ),
    cloudEpubContentFileName(title): null,
  };
}

/// 计数 HEAD 探针（`findAsset`）与 JSON 下载（`getJsonAsset`）的资产库后端。
class _CountingAssetBackend extends FakeSyncBackend {
  _CountingAssetBackend(super.store);

  int findAssetCalls = 0;
  int jsonDownloads = 0;

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) {
    findAssetCalls++;
    return super.findAsset(namespaceId, name);
  }

  @override
  Future<Object?> getJsonAsset(String assetId) {
    jsonDownloads++;
    return super.getJsonAsset(assetId);
  }
}

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('sync_rt_budget_');
  });
  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  group('书阶段（无快照后端）', () {
    test('未变的书：每本只列一次文件夹，不重列、不探针、不重写基线', () async {
      final _CountingDb db = _CountingDb();
      addTearDown(db.close);
      final _FolderBackend backend = _FolderBackend();
      const int n = 6;
      for (int i = 0; i < n; i++) {
        await _seedSettledBook(db, backend, work, 'Old Book $i');
      }
      db.baselineWrites = 0;

      final BookFolderListingObservations seen =
          BookFolderListingObservations();
      final List<SyncBookResult> results =
          await SyncManager(db: db, backend: backend).syncAllBooks(
            syncStats: true,
            statsSyncMode: StatisticsSyncMode.merge,
            syncAudioBook: false,
            syncContent: true,
            observations: seen,
          );

      expect(
        results.map((SyncBookResult r) => r.direction),
        everyElement(SyncResult.synced),
      );
      // 修前：listSyncFiles n 次 + 补传书文件再 listChildren n 次 = 2n 次往返。
      expect(backend.listSyncFilesCalls, n);
      expect(backend.listChildrenCalls, 0);
      expect(backend.contentProbes, 0);
      expect(backend.contentUploads, 0);
      expect(backend.jsonWrites, 0);
      // 修前：每本未变的书每轮重写一次同一个基线值（n 次写库）。
      expect(db.baselineWrites, 0);
      // 同轮后续阶段可复用的列举所见。
      expect(seen.folderCount, n);
      expect(
        seen.namesOf(backend.folderOf('Old Book 0')),
        contains(cloudEpubContentFileName('Old Book 0')),
      );
    });

    test('逐本列举改为有界并发预取：请求数不变、结论不变、不再串行排队', () async {
      final _CountingDb db = _CountingDb();
      addTearDown(db.close);
      final _FolderBackend backend = _FolderBackend();
      const int n = 8;
      for (int i = 0; i < n; i++) {
        await _seedSettledBook(db, backend, work, 'Shelf Book $i');
      }
      Future<List<SyncBookResult>> sweep() =>
          SyncManager(db: db, backend: backend).syncAllBooks(
            syncStats: false,
            statsSyncMode: StatisticsSyncMode.merge,
            syncAudioBook: false,
            syncContent: true,
          );
      // 第一轮把 title→folderId 缓存建起来（真实后端同样在首轮学到它）。
      await sweep();
      backend
        ..listSyncFilesCalls = 0
        ..listChildrenCalls = 0
        ..maxInFlight = 0
        ..listLatency = const Duration(milliseconds: 30);

      final List<SyncBookResult> results = await sweep();

      expect(
        results.map((SyncBookResult r) => r.direction),
        everyElement(SyncResult.synced),
      );
      expect(backend.listSyncFilesCalls, n, reason: '每本仍只列一次');
      expect(backend.listChildrenCalls, 0);
      // 修前：严格串行，maxInFlight 恒为 1（n 本书 = n 次往返的墙钟时间）。
      expect(backend.maxInFlight, greaterThan(1));
    });

    test('同名书共用一个文件夹：不预取，按顺序现列', () async {
      final _CountingDb db = _CountingDb();
      addTearDown(db.close);
      final _FolderBackend backend = _FolderBackend();
      await _seedSettledBook(db, backend, work, 'Twin');
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Twin copy',
          title: 'Twin',
          epubPath: 'Twin copy.epub',
          extractDir: '${work.path}/Twin',
          chapterCount: 1,
          chaptersJson: _chapters,
          importedAt: 2,
        ),
      );
      Future<void> sweep() =>
          SyncManager(db: db, backend: backend).syncAllBooks(
            syncStats: false,
            statsSyncMode: StatisticsSyncMode.merge,
            syncAudioBook: false,
          );
      await sweep();
      backend
        ..listSyncFilesCalls = 0
        ..maxInFlight = 0
        ..listLatency = const Duration(milliseconds: 20);
      await sweep();
      expect(backend.listSyncFilesCalls, 2);
      expect(backend.maxInFlight, 1);
    });

    test('列举方给不出完整清单（fileNames == null）时照旧自己列一次', () async {
      final _CountingDb db = _CountingDb();
      addTearDown(db.close);
      final _IncompleteListingBackend backend = _IncompleteListingBackend();
      await _seedSettledBook(db, backend, work, 'Paged Book');

      await SyncManager(db: db, backend: backend).syncAllBooks(
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
        syncContent: true,
      );

      expect(backend.listSyncFilesCalls, 1);
      expect(backend.listChildrenCalls, 1);
      expect(backend.contentUploads, 0, reason: '远端已有的书文件不能重传');
    });

    test('导出一本书的统计只读这本书的行，不整表扫描', () async {
      final _CountingDb db = _CountingDb();
      addTearDown(db.close);
      final _FolderBackend backend = _FolderBackend();
      await _seedSettledBook(db, backend, work, 'Read Today');
      // 本机今天读过：本地进度比基线 / 远端新 → 导出。
      final String uid = (await db.resolveEpubBookUid('Read Today'))!;
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value<String>(uid),
          sectionIndex: const Value<int>(0),
          normCharOffset: const Value<int>(6000),
          updatedAt: const Value<int>(2000),
        ),
      );
      for (final String title in <String>['Read Today', 'Other Book']) {
        await db.setReadingStatistic(
          ReadingStatisticsCompanion(
            title: Value<String>(title),
            dateKey: const Value<String>('2026-11-03'),
            charactersRead: const Value<int>(120),
            readingTimeMs: const Value<int>(60000),
            lastStatisticModified: const Value<int>(2000),
          ),
        );
      }

      final List<SyncBookResult> results =
          await SyncManager(db: db, backend: backend).syncAllBooks(
            syncStats: true,
            statsSyncMode: StatisticsSyncMode.merge,
            syncAudioBook: false,
          );

      expect(results.single.direction, SyncResult.exported);
      expect(db.fullStatsScans, 0, reason: '修前：每导入 / 导出一本书整表读一次');
      expect(
        backend.statsUploads.single.map((TtuStatistics s) => s.title),
        <String>['Read Today'],
      );
    });
  });

  group('有声书包阶段', () {
    late FakeAssetStore store;
    late _CountingAssetBackend backend;
    late FushiDatabase db;

    SyncOrchestrator orch() => SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: work,
      audioDatabaseRoot: work,
      tempDir: work,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncMangaContent: false,
      syncAudioBookFiles: true,
      syncDictionary: false,
    );

    setUp(() async {
      store = FakeAssetStore();
      backend = _CountingAssetBackend(store);
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final Directory audioRoot = Directory('${work.path}/audio')..createSync();
      final File track = File('${audioRoot.path}/track.mp3')
        ..writeAsStringSync('audio');
      final File align = File('${audioRoot.path}/align.srt')
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhi\n');
      final String key = await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Audio Book',
          title: 'Audio Book',
          epubPath: '/fake/a.epub',
          extractDir: '/fake/a',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1,
        ),
      );
      await db.upsertAudiobook(
        AudiobooksCompanion.insert(
          bookKey: key,
          audioRoot: Value<String?>(audioRoot.path),
          audioPathsJson: Value<String>(jsonEncode(<String>[track.path])),
          alignmentFormat: 'srt',
          alignmentPath: align.path,
        ),
      );
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: 'srt-$key',
          title: 'Audio Book',
          audioRoot: Value<String?>(audioRoot.path),
          audioPathsJson: Value<String>(jsonEncode(<String>[track.path])),
          srtPath: align.path,
          importedAt: 1,
          bookKey: Value<String>(key),
        ),
      );
      // 第一轮把包传上去（远端此前没有）。
      final SyncRunReport first = SyncRunReport();
      await orch().syncAudiobookPackages('root', first);
      expect(first.errors, isEmpty, reason: first.errors.join(' | '));
      expect(first.audiobooksExported, 1);
      backend.findAssetCalls = 0;
    });

    test('书阶段已列到包名：不再 HEAD，也不重传', () async {
      final String folderId = await backend.ensureBookFolder(
        bookTitle: 'Audio Book',
        rootFolderId: 'root',
      );
      final BookFolderListingObservations seen = BookFolderListingObservations()
        ..record(folderId, <String>{kSyncAudiobookAssetName});

      final SyncRunReport report = SyncRunReport();
      await orch().syncAudiobookPackages('root', report, bookFolderNames: seen);

      // 修前：每本有声书每轮 1 次 HEAD（远端只有 Hibiki 旧名时 2 次）。
      expect(backend.findAssetCalls, 0);
      expect(report.audiobooksExported, 0);
    });

    test('Hibiki 旧名同样算已有', () async {
      final String folderId = await backend.ensureBookFolder(
        bookTitle: 'Audio Book',
        rootFolderId: 'root',
      );
      final SyncRunReport report = SyncRunReport();
      await orch().syncAudiobookPackages(
        'root',
        report,
        bookFolderNames: BookFolderListingObservations()
          ..record(folderId, <String>{kLegacySyncAudiobookAssetName}),
      );
      expect(backend.findAssetCalls, 0);
      expect(report.audiobooksExported, 0);
    });

    test('列举里没看见包名：照旧实时确认，远端其实有就不重传', () async {
      final String folderId = await backend.ensureBookFolder(
        bookTitle: 'Audio Book',
        rootFolderId: 'root',
      );
      final SyncRunReport report = SyncRunReport();
      await orch().syncAudiobookPackages(
        'root',
        report,
        bookFolderNames: BookFolderListingObservations()
          ..record(folderId, const <String>{}),
      );
      expect(backend.findAssetCalls, 1);
      expect(report.audiobooksExported, 0);
    });
  });

  group('per-device 清单镜像', () {
    late FakeAssetStore store;

    setUp(() {
      store = FakeAssetStore(reportRevisions: true);
    });

    SyncOrchestrator orchFor(
      FushiDatabase db,
      SyncBackend backend,
      String deviceId,
    ) => SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: work,
      audioDatabaseRoot: work,
      tempDir: work,
      deviceId: deviceId,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncMangaContent: false,
      syncAudioBookFiles: false,
      syncDictionary: false,
      remoteManifestMirror: DirectoryAggregatePeerSnapshotCache(
        () async => Directory('${work.path}/mirror_$deviceId'),
      ),
    );

    Future<void> tick() async {
      final int start = DateTime.now().millisecondsSinceEpoch;
      while (DateTime.now().millisecondsSinceEpoch <= start) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }

    test('合集清单：对端没变就不重下，变了照样下载并折进来', () async {
      final FushiDatabase dbA = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final FushiDatabase dbB = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final _CountingAssetBackend a = _CountingAssetBackend(store);
      final _CountingAssetBackend b = _CountingAssetBackend(store);

      final int fav = await dbA.createMediaCollection('Fav');
      await dbA.addToCollection(fav, MediaKind.epub, 'x');
      await tick();
      await orchFor(dbA, a, 'devA').syncCollections(SyncRunReport());
      await tick();

      Future<int> syncB() async {
        b.jsonDownloads = 0;
        final SyncRunReport r = SyncRunReport();
        await orchFor(dbB, b, 'devB').syncCollections(r);
        expect(r.errors, isEmpty, reason: r.errors.join(' | '));
        await tick();
        return b.jsonDownloads;
      }

      expect(await syncB(), 1, reason: '首轮：只有 A 的清单');
      // 第二轮：A 那份没变（命中镜像）；B 自己那份上轮刚写过、版本变了，读一次。
      expect(await syncB(), 1);
      // 稳态：两份都没变。修前：每轮 2 次下载（每台设备一份）。
      expect(await syncB(), 0);

      final MediaCollectionRow? row = await dbB.getMediaCollectionByNaturalKey(
        'Fav',
        'collection',
      );
      expect(row, isNotNull);

      // A 改了合集：版本变了，B 必须重下并看到新成员。
      await dbA.addToCollection(fav, MediaKind.epub, 'y');
      await tick();
      await orchFor(dbA, a, 'devA').syncCollections(SyncRunReport());
      await tick();
      expect(await syncB(), 1);
      expect(
        (await dbB.getCollectionItems(
          row!.id,
        )).map((MediaCollectionItemRow m) => m.entryKey),
        containsAll(<String>['x', 'y']),
      );
    });

    test('删除墓碑合并清单：稳态不重下任何一份', () async {
      final FushiDatabase dbA = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final FushiDatabase dbB = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final _CountingAssetBackend a = _CountingAssetBackend(store);
      final _CountingAssetBackend b = _CountingAssetBackend(store);
      await dbA.writeSyncDeletionTombstone('book', 'Gone Book', 1000);
      await orchFor(dbA, a, 'devA').syncDeletionTombstones(SyncRunReport());

      final List<int> downloads = <int>[];
      for (int i = 0; i < 4; i++) {
        b.jsonDownloads = 0;
        final SyncRunReport r = SyncRunReport();
        await orchFor(dbB, b, 'devB').syncDeletionTombstones(r);
        expect(r.errors, isEmpty, reason: r.errors.join(' | '));
        downloads.add(b.jsonDownloads);
      }
      // 首轮读 A 的清单（逐条标记已被清单覆盖），之后收敛到 0。修前：每轮至少
      // 把每台设备的清单各下一次（这里每轮 2 次）。
      expect(downloads.first, greaterThan(0));
      expect(downloads.last, 0, reason: 'downloads per round: $downloads');
    });
  });
}

/// 列举方不给完整文件名清单（如 Drive 只取了第一页）。
class _IncompleteListingBackend extends _FolderBackend {
  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    listSyncFilesCalls++;
    return syncFileTrioFromFiles(<SyncFileRef>[
      for (final String name in folders[folderId]!.keys)
        SyncFileRef(id: '$folderId$name', name: name),
    ], complete: false);
  }
}
