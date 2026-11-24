import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/book_change_gate.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart'
    show syncExitedBookOnChannel;
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_peer_snapshot_cache.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart'
    show aggregateSnapshotDeviceOf;
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_engine/sync/ttu_models.dart';

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

// wiO0nN8aiG / issue #4332：只开统计同步、远端没变时，书阶段不再每轮逐本列举整个
// 书库。设计见 docs/specs/2026-11-24-sync-book-change-manifest.md。
//
// 这里跑的是真实的 SyncOrchestrator.run：两台（或三台）设备共用一份内存远端，
// 计数逐本列举（listSyncFiles）与「阅读数据」阶段的逐本进度事件。

/// 路径式、无快照的书文件夹后端（WebDAV / OneDrive / FTP / SFTP 的形状），书文件夹
/// 与保留命名空间都落在同一份 [FakeAssetStore] 里，多台设备共用。
class _BookFolderBackend extends FakeSyncBackend {
  _BookFolderBackend(this.store) : super(store);

  final FakeAssetStore store;
  int listSyncFilesCalls = 0;

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    listSyncFilesCalls++;
    return syncFileTrioFromFiles(<SyncFileRef>[
      for (final AssetEntry e in await store.listChildren(folderId))
        if (!e.isFolder) SyncFileRef(id: e.id, name: e.name),
    ]);
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async =>
      TtuProgress.fromJson(
        (await store.getJsonAsset(fileId))! as Map<String, dynamic>,
      );

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async =>
      const <TtuStatistics>[];

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) => writeProgress(folderId, progress);

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {}

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {}

  /// 写进度文件（也给「旧版客户端 / ッツ网页版」直接改远端用）。
  Future<void> writeProgress(String folderId, TtuProgress progress) async {
    for (final AssetEntry e in await store.listChildren(folderId)) {
      if (e.name.startsWith('progress_')) await store.deleteAsset(e.id);
    }
    await store.putJsonAsset(
      folderId,
      progressFileName(progress.lastBookmarkModified, progress.progress),
      progress.toJson(),
    );
  }
}

/// 同一份远端，但能一次列出整棵树（Drive / Dropbox / 服务器的形状）。
class _SnapshotBackend extends _BookFolderBackend
    implements RemoteListingCapable {
  _SnapshotBackend(super.store);

  int snapshots = 0;

  @override
  Future<RemoteListingSnapshot?> snapshotListing(String rootFolderId) async {
    snapshots++;
    final Map<String, List<AssetEntry>> folders = <String, List<AssetEntry>>{};
    for (final AssetEntry f in await store.listChildren(rootFolderId)) {
      if (f.isFolder) folders[f.name] = await store.listChildren(f.id);
    }
    // 假后端的命名空间在顶层（ensureNamespace 不挂在 root 下），一并列出。
    for (final AssetEntry f in await store.listChildren('')) {
      if (f.isFolder && f.name != rootFolderId) {
        folders[f.name] = await store.listChildren(f.id);
      }
    }
    return RemoteListingSnapshot(folders);
  }
}

const String _chapters = '[{"title":"c1","characters":1000}]';

class _Device {
  _Device(this.id, this.backend, this.work)
    : db = FushiDatabase.forTesting(NativeDatabase.memory());

  final String id;
  final _BookFolderBackend backend;
  final Directory work;
  final FushiDatabase db;
  final List<SyncProgress> events = <SyncProgress>[];

  Future<void> addBook(String title, {int? readAt, int offset = 5000}) async {
    final Directory extract = Directory('${work.path}/$id/$title')
      ..createSync(recursive: true);
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
    if (readAt != null) await read(title, readAt, offset: offset);
  }

  Future<void> read(String title, int at, {int offset = 5000}) async {
    final String uid = (await db.resolveEpubBookUid(title))!;
    await db.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value<String>(uid),
        sectionIndex: const Value<int>(0),
        normCharOffset: Value<int>(offset),
        updatedAt: Value<int>(at),
      ),
    );
  }

  Future<int?> positionAt(String title) async {
    final String uid = (await db.resolveEpubBookUid(title))!;
    return (await db.getReaderPosition(uid))?.updatedAt;
  }

  /// 跑一轮整轮同步，返回报告；[listings] 是这一轮的逐本列举次数。
  Future<({SyncRunReport report, int listings, int bookEvents})> run() async {
    await pinDeviceId();
    backend.listSyncFilesCalls = 0;
    events.clear();
    final SyncRunReport report = await SyncOrchestrator(
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
      onProgress: events.add,
      remoteManifestMirror: DirectoryAggregatePeerSnapshotCache(
        () async => Directory('${work.path}/mirror_$id'),
      ),
    ).run();
    return (
      report: report,
      listings: backend.listSyncFilesCalls,
      bookEvents: events
          .where(
            (SyncProgress e) =>
                e.phase == SyncPhase.readingData && e.itemTotal > 0,
          )
          .length,
    );
  }

  /// 生产里编排器的 deviceId 与单本同步发布清单用的是同一个
  /// `SyncRepository.getOrCreateDeviceId`；测试给编排器传了固定 id，这里让两者一致。
  Future<void> pinDeviceId() => db.setPref('sync_device_id', id);

  Future<BookChangeState> state() =>
      BookChangeState.load(db, progressBaselineDimensionOf(backend));
}

void main() {
  late Directory work;
  late FakeAssetStore store;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('book_change_gate_');
    store = FakeAssetStore(reportRevisions: true);
  });
  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  _Device device(String id, {bool snapshot = false}) {
    final _Device d = _Device(
      id,
      snapshot ? _SnapshotBackend(store) : _BookFolderBackend(store),
      work,
    );
    addTearDown(d.db.close);
    return d;
  }

  /// 两台设备各读过 / 各导入过同一批书，跑到双方都稳态（每轮 0 次逐本列举）。
  Future<void> settle(List<_Device> devices) async {
    for (int round = 0; round < 3; round++) {
      for (final _Device d in devices) {
        await d.run();
      }
    }
  }

  group('无快照后端（manifest 模式）', () {
    test('远端与本地都没变：稳态 0 次逐本列举、0 条逐本进度', () async {
      final _Device a = device('devA');
      const int n = 6;
      for (int i = 0; i < n; i++) {
        await a.addBook('Book $i', readAt: 1000 + i);
      }
      // 第一轮：全导出（首轮，本机清单不在 → 全扫）。
      final r1 = await a.run();
      expect(r1.listings, n);
      expect(r1.report.errors, isEmpty);
      // 第二轮：导出后的书再亲眼确认一次两端一致，记下指纹。
      final r2 = await a.run();
      expect(r2.listings, n);
      expect(r2.report.booksUnchanged, 0);
      // 第三轮起：一本都不列。
      final r3 = await a.run();
      expect(r3.listings, 0, reason: '修前每轮 n 次');
      expect(r3.bookEvents, 0, reason: '进度条不再逐本走过未变的书');
      expect(r3.report.booksUnchanged, n);
      expect(r3.report.booksChecked, 0);
      expect(r3.report.bookChangeMode, 'manifest');
      expect(r3.report.errors, isEmpty);
    });

    test('本机读过的书照常进逐本阶段，其余跳过', () async {
      final _Device a = device('devA');
      for (int i = 0; i < 4; i++) {
        await a.addBook('Book $i', readAt: 1000);
      }
      await settle(<_Device>[a]);
      await a.read('Book 2', 2000);
      final r = await a.run();
      expect(r.listings, 1);
      expect(r.bookEvents, greaterThan(0));
      expect(r.report.booksUnchanged, 3);
    });

    test('多设备：A 读一本 → B 下一轮只列那一本并导入，然后双方收敛', () async {
      final _Device a = device('devA');
      final _Device b = device('devB');
      for (int i = 0; i < 3; i++) {
        await a.addBook('Book $i', readAt: 1000);
        await b.addBook('Book $i');
      }
      await settle(<_Device>[a, b]);
      expect(await b.positionAt('Book 0'), 1000, reason: 'B 首轮已导入');
      expect((await a.run()).listings, 0);
      expect((await b.run()).listings, 0);

      await a.read('Book 1', 2000, offset: 8000);
      expect((await a.run()).listings, 1, reason: 'A 只导出读过的那本');

      final rb = await b.run();
      expect(rb.listings, 1, reason: 'B 只列清单里变了的那本');
      expect(await b.positionAt('Book 1'), 2000);

      // B 的导入推进了它的基线（清单条目变了）：A 多确认一次那本书后收敛。
      expect((await a.run()).listings, 1);
      expect((await b.run()).listings, 1, reason: 'B 导入后亲眼确认一次');
      expect((await a.run()).listings, 0);
      expect((await b.run()).listings, 0);
    });

    test('退出书单本同步也发布清单：B 不必等 A 的下一轮整轮同步', () async {
      final _Device a = device('devA');
      final _Device b = device('devB');
      for (int i = 0; i < 3; i++) {
        await a.addBook('Book $i', readAt: 1000);
        await b.addBook('Book $i');
      }
      await settle(<_Device>[a, b]);

      await a.read('Book 2', 3000, offset: 9000);
      final EpubBookRow book = (await a.db.getAllEpubBooks()).firstWhere(
        (EpubBookRow r) => r.title == 'Book 2',
      );
      await a.pinDeviceId();
      await syncExitedBookOnChannel(
        db: a.db,
        repo: SyncRepository(a.db),
        backend: a.backend,
        book: book,
      );

      final rb = await b.run();
      expect(rb.listings, 1);
      expect(await b.positionAt('Book 2'), 3000);
    });

    test('旧版客户端混跑：只写书文件 + 聚合快照、不写清单 → 回退全扫并导入', () async {
      final _Device a = device('devA');
      final _Device b = device('devB');
      for (int i = 0; i < 3; i++) {
        await a.addBook('Book $i', readAt: 1000);
        await b.addBook('Book $i');
      }
      await settle(<_Device>[a, b]);

      // 旧版客户端 devOld：改了 Book 0 的进度文件，写了自己的聚合快照，没有书级清单。
      final _BookFolderBackend legacy = _BookFolderBackend(store);
      final String folder = await legacy.ensureBookFolder(
        bookTitle: 'Book 0',
        rootFolderId: 'root',
      );
      await legacy.writeProgress(
        folder,
        TtuProgress(
          dataId: 0,
          exploredCharCount: 900,
          progress: 0.9,
          lastBookmarkModified: 5000,
        ),
      );
      final String agg = await store.ensureNamespace('__aggregate__');
      await store.putJsonAsset(agg, 'devOld.fushiaggregate', <String, int>{
        'v': 1,
      });

      final rb = await b.run();
      expect(rb.listings, 3, reason: '旧客户端在活动：全扫');
      expect(rb.report.bookChangeMode, contains('legacy writer devOld'));
      expect(await b.positionAt('Book 0'), 5000);

      // 旧客户端的快照没再变：恢复跳过（刚导入的那本再确认一次）。
      expect((await b.run()).listings, 1);
      expect((await b.run()).listings, 0);

      // 它再写一次快照 → 又全扫一次。
      await store.putJsonAsset(agg, 'devOld.fushiaggregate', <String, int>{
        'v': 2,
      });
      expect((await b.run()).listings, 3);
    });

    test('不写清单也不写聚合快照的写入者：由 24 小时兜底全扫补上', () async {
      final _Device a = device('devA');
      for (int i = 0; i < 3; i++) {
        await a.addBook('Book $i', readAt: 1000);
      }
      await settle(<_Device>[a]);

      // ッツ网页版之类：直接改 Book 1 的进度文件。
      final String folder = await a.backend.ensureBookFolder(
        bookTitle: 'Book 1',
        rootFolderId: 'root',
      );
      await a.backend.writeProgress(
        folder,
        TtuProgress(
          dataId: 0,
          exploredCharCount: 700,
          progress: 0.7,
          lastBookmarkModified: 6000,
        ),
      );
      expect((await a.run()).listings, 0, reason: '24 小时内看不见它（只是晚导入，不会写）');
      expect(await a.positionAt('Book 1'), 1000);

      final BookChangeState s = await a.state();
      s.lastFullSweepMs =
          DateTime.now().millisecondsSinceEpoch -
          kBookChangeFullSweepInterval.inMilliseconds -
          1;
      await s.save(a.db, progressBaselineDimensionOf(a.backend));

      final r = await a.run();
      expect(r.listings, 3);
      expect(r.report.bookChangeMode, contains('periodic full sweep'));
      expect(await a.positionAt('Book 1'), 6000);
    });

    test('对端清单损坏 → 本轮全扫并记错误；本机清单被删 → 全扫并重新发布', () async {
      final _Device a = device('devA');
      final _Device b = device('devB');
      for (int i = 0; i < 3; i++) {
        await a.addBook('Book $i', readAt: 1000);
        await b.addBook('Book $i');
      }
      await settle(<_Device>[a, b]);

      await store.putJsonAsset(
        kSyncBookManifestNamespace,
        bookManifestNameFor('devA'),
        <String, Object?>{'v': 'garbage'},
      );
      final rb = await b.run();
      expect(rb.listings, 3);
      expect(
        rb.report.errors.where((String e) => e.contains('books-devA.json')),
        isNotEmpty,
      );

      // A 自己的清单被改坏 / 删掉：A 全扫并强制重发。
      final ra = await a.run();
      expect(ra.listings, 3);
      expect(ra.report.bookChangeMode, contains('own manifest'));
      final Object? republished = await store.getJsonAsset(
        '$kSyncBookManifestNamespace/${bookManifestNameFor('devA')}',
      );
      expect(BookChangeManifest.fromJson(republished).books, hasLength(3));

      await store.deleteAsset(
        '$kSyncBookManifestNamespace/${bookManifestNameFor('devA')}',
      );
      expect((await a.run()).listings, 3);
      expect(
        await store.getJsonAsset(
          '$kSyncBookManifestNamespace/${bookManifestNameFor('devA')}',
        ),
        isNotNull,
      );
      // 恢复后 B 收敛回 0。
      await settle(<_Device>[a, b]);
      expect((await b.run()).listings, 0);
    });

    test('冲突书每轮照报，不会被指纹吞掉', () async {
      final _Device a = device('devA');
      final _Device b = device('devB');
      await a.addBook('Fork', readAt: 1000);
      await b.addBook('Fork');
      await settle(<_Device>[a, b]);

      await a.read('Fork', 2000, offset: 7000);
      await a.run();
      await b.read('Fork', 2500, offset: 2000);
      final r1 = await b.run();
      expect(r1.report.conflicts, hasLength(1));
      final r2 = await b.run();
      expect(r2.report.conflicts, hasLength(1));
      expect(r2.listings, 1);
    });
  });

  group('快照后端（snapshot 模式）', () {
    test('不写清单的写入者改了书文件夹也精确命中，只同步那一本', () async {
      final _Device a = device('devA', snapshot: true);
      const int n = 5;
      for (int i = 0; i < n; i++) {
        await a.addBook('Book $i', readAt: 1000);
      }
      await settle(<_Device>[a]);
      final r0 = await a.run();
      expect(r0.report.bookChangeMode, 'snapshot');
      expect(r0.report.booksChecked, 0);
      expect(r0.report.booksUnchanged, n);
      expect(r0.bookEvents, 0);

      final String folder = await a.backend.ensureBookFolder(
        bookTitle: 'Book 3',
        rootFolderId: 'root',
      );
      await a.backend.writeProgress(
        folder,
        TtuProgress(
          dataId: 0,
          exploredCharCount: 800,
          progress: 0.8,
          lastBookmarkModified: 7000,
        ),
      );
      final r = await a.run();
      expect(r.report.booksChecked, 1);
      expect(r.report.booksUnchanged, n - 1);
      expect(await a.positionAt('Book 3'), 7000);
      expect(a.backend.listSyncFilesCalls, 0, reason: '快照模式本来就不逐本列举');
    });
  });

  test('指纹最低位记有声书包：跳过的书把观测喂给同轮有声书包阶段', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    BookChangeGate gate(Map<String, int> fps) => BookChangeGate(
      mode: BookChangeGateMode.manifest,
      storageDimension: 'progress',
      fingerprints: fps,
      audioPackageNames: const <String>{'audiobook.fushiaudio'},
    );
    final BookChangeGate first = gate(<String, int>{});
    await first.recordAgreement(
      db: db,
      assetKey: 'With Audio',
      localStamp: 10,
      contentChecked: false,
      remoteFileNames: <String>{'progress_x.json', 'audiobook.fushiaudio'},
    );
    await first.recordAgreement(
      db: db,
      assetKey: 'Plain',
      localStamp: 10,
      contentChecked: false,
      remoteFileNames: <String>{'progress_x.json'},
    );
    final BookChangeGate next = gate(
      await db.getSyncBaselinesForDimension(
        BookChangeGate.fingerprintDimensionFor('progress'),
      ),
    );
    for (final String key in <String>['With Audio', 'Plain']) {
      expect(
        next.canSkip(assetKey: key, localStamp: 10, contentChecked: false),
        isTrue,
      );
      expect(
        next.canSkip(assetKey: key, localStamp: 11, contentChecked: false),
        isFalse,
        reason: '本地动过',
      );
      expect(
        next.canSkip(assetKey: key, localStamp: 10, contentChecked: true),
        isFalse,
        reason: '内容开关刚打开：要去补传',
      );
    }
    expect(next.audioPackageSeen('With Audio'), isTrue);
    expect(next.audioPackageSeen('Plain'), isFalse);

    final BookFolderListingObservations seen = BookFolderListingObservations();
    seen.noteSeenFromFingerprint('root/With Audio', next.audioPackageNames);
    expect(seen.namesOf('root/With Audio'), contains('audiobook.fushiaudio'));
  });

  test('清单 wire 形状：键排序、坏形状抛 FormatException', () {
    const BookChangeManifest m = BookChangeManifest(
      deviceId: 'd',
      books: <String, int>{'b': 2, 'a': 1},
    );
    expect(
      jsonEncode(m.toJson()),
      '{"v":1,"device":"d","books":{"a":1,"b":2}}',
    );
    expect(
      BookChangeManifest.fromJson(m.toJson()).contentHash(),
      m.contentHash(),
    );
    expect(
      () => BookChangeManifest.fromJson(<String, Object?>{'v': 1}),
      throwsFormatException,
    );
    expect(bookManifestDeviceOf('books-abc.json'), 'abc');
    expect(bookManifestDeviceOf('collections-abc.json'), isNull);
  });

  // 旧版客户端检测认的聚合快照名与聚合同步本身同源（引擎 aggregate_sync_service），
  // Hibiki 时代旧后缀的快照（云根迁移原样保留）也认得出写它的设备。
  test('聚合快照名 → 设备 id：新旧后缀都认，空设备 / 非快照返回 null', () {
    expect(aggregateSnapshotDeviceOf('devA.fushiaggregate'), 'devA');
    expect(aggregateSnapshotDeviceOf('devB.hibikiaggregate'), 'devB');
    expect(aggregateSnapshotDeviceOf('.fushiaggregate'), isNull);
    expect(aggregateSnapshotDeviceOf('books-devA.json'), isNull);
  });
}
