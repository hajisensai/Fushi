/// 反馈 R8duEiqRuy（所有者 2026-10-31 追加）：云盘备份来源的远端书也能「同时从远端
/// 删除」。钉住三件事：
///
/// 1. [CloudRemoteBookClient.deleteRemoteBook]：删掉这本书在云盘上的全部对象（书文件夹
///    里的内容包 / 封面 / 进度·统计·有声书位置 JSON / 有声书包），先发布云删除墓碑
///    （`__tombstones__/` 逐条标记 + 本机墓碑表），再删文件夹；墓碑写不进去就什么都
///    不删；六种云盘后端走同一条路径。
/// 2. [CloudRemoteBookClient.probeRemoteReachability]：可达 / 连不上 / 登录失效三态，
///    菜单项的可用性由它决定。
/// 3. 其它设备不会把它拉回来：持有旧副本的设备下一轮云同步**不**重建书文件夹（书阶段
///    之前先读墓碑做推送否决），并收到「其他设备已删除」确认候选；删除之后才重新加入
///    的书照常同步。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/cloud_remote_book_client.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

/// 共享 [FakeAssetStore] 上的云盘后端：补上书架列举 / 书文件夹缓存 / 单本书同步用到的
/// 成员，并记录 `ensureBookFolder`（= 会不会把书文件夹建回云盘）。
class _CloudBackend extends FakeSyncBackend {
  _CloudBackend(this.store) : super(store);
  final FakeAssetStore store;

  final List<String> ensuredBookFolders = <String>[];
  final List<String> evicted = <String>[];
  Exception? listChildrenError;
  Exception? putJsonError;
  Exception? deleteError;

  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async =>
      <SyncFileRef>[
        for (final AssetEntry e in await store.listChildren(rootFolderId))
          if (e.isFolder) SyncFileRef(id: e.id, name: e.name),
      ];

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    final Exception? error = listChildrenError;
    if (error != null) throw error;
    return super.listChildren(namespaceId);
  }

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) {
    final Exception? error = putJsonError;
    if (error != null) throw error;
    return super.putJsonAsset(namespaceId, name, json);
  }

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) {
    final Exception? error = deleteError;
    if (error != null) throw error;
    return super.deleteAsset(id, isFolder: isFolder);
  }

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) {
    ensuredBookFolders.add(bookTitle);
    return store.ensureFolder(rootFolderId, sanitizeTtuFilename(bookTitle));
  }

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async =>
      const SyncFileTrio();

  @override
  void evictFolderId(String folderId) => evicted.add(folderId);
}

/// 云盘上的一本书：书文件夹 + 同步会写进去的全部对象。
Future<void> _seedCloudBook(FakeAssetStore store, String title) async {
  final String folder = await store.ensureFolder(
    'root',
    sanitizeTtuFilename(title),
  );
  final Directory tmp = await Directory.systemTemp.createTemp('cloud_seed');
  addTearDown(() => tmp.delete(recursive: true));
  final File bytes = File('${tmp.path}/b')..writeAsBytesSync(<int>[1, 2, 3]);
  final String key = sanitizeTtuFilename(title);
  for (final String name in <String>[
    '$key.epub',
    'cover.jpg',
    kSyncAudiobookAssetName,
  ]) {
    await store.putAsset(folder, name, bytes);
  }
  await store.putJsonAsset(folder, 'progress_$key.json', <String, Object?>{});
  await store.putJsonAsset(folder, 'statistics_$key.json', <Object?>[]);
}

Future<List<String>> _allPaths(FakeAssetStore store, String parent) async {
  final List<String> out = <String>[];
  for (final AssetEntry e in await store.listChildren(parent)) {
    out.add(e.id);
    if (e.isFolder) out.addAll(await _allPaths(store, e.id));
  }
  return out;
}

void main() {
  late FakeAssetStore store;
  late _CloudBackend backend;
  late FushiDatabase db;

  setUp(() {
    store = FakeAssetStore();
    backend = _CloudBackend(store);
    db = _memDb();
  });
  tearDown(() => db.close());

  CloudRemoteBookClient client({
    SyncBackendType type = SyncBackendType.webDav,
    FushiDatabase? database,
    bool withDb = true,
  }) => CloudRemoteBookClient(
    backend: backend,
    backendType: type,
    rootFolderId: 'root',
    database: withDb ? (database ?? db) : null,
    contentProbeRetryBackoff: Duration.zero,
  );

  Future<RemoteBookInfo> listed(CloudRemoteBookClient c, String title) async =>
      (await c.listRemoteBooks()).singleWhere(
        (RemoteBookInfo b) => b.title == title,
      );

  Future<Object?> cloudMarker(String itemKey) async {
    final AssetEntry? e = await store.findAsset(
      kSyncTombstonesNamespace,
      deletionTombstoneAssetName(SyncTombstoneKind.book.dbValue, itemKey),
    );
    return e == null ? null : store.getJsonAsset(e.id);
  }

  group('deleteRemoteBook', () {
    // 六种云盘后端共用这一条路径（各后端的 deleteAsset(isFolder) 都是递归删）。
    for (final SyncBackendType type in SyncBackendType.values.where(
      (SyncBackendType t) => t != SyncBackendType.fushiServer,
    )) {
      test('$type：删掉书文件夹里的全部对象 + 发布墓碑，别的书不动', () async {
        await _seedCloudBook(store, 'Book A');
        await _seedCloudBook(store, 'Book B');
        final CloudRemoteBookClient c = client(type: type);
        final RemoteBookInfo a = await listed(c, 'Book A');

        await c.deleteRemoteBook(a);

        final List<String> left = await _allPaths(store, 'root');
        expect(left.where((String p) => p.startsWith('root/Book A')), isEmpty);
        expect(
          left.where((String p) => p.startsWith('root/Book B')),
          hasLength(6),
        );
        expect(
          (await c.listRemoteBooks()).map((RemoteBookInfo b) => b.title),
          <String>['Book B'],
        );
        expect(backend.evicted, <String>[a.downloadId]);

        final Object? marker = await cloudMarker('Book A');
        expect(marker, isA<Map<String, Object?>>());
        final ({String mediaType, String itemKey, int deletedAt})? parsed =
            parseDeletionTombstoneJson(marker);
        expect(parsed?.mediaType, SyncTombstoneKind.book.dbValue);
        expect(parsed?.itemKey, 'Book A');

        final SyncDeletionTombstoneRow row =
            (await db.getSyncDeletionTombstones()).single;
        expect(row.itemKey, 'Book A');
        expect(row.deletedAt, parsed?.deletedAt);
        expect(row.remotePublishedAt, greaterThan(0), reason: '标记已直接发布');
      });
    }

    test('墓碑键 = 文件夹名（书名含需转义字符时与其它设备的 bookKey 一致）', () async {
      await _seedCloudBook(store, 'Re:Zero');
      final CloudRemoteBookClient c = client();
      final RemoteBookInfo book = await listed(c, 'Re:Zero');
      await c.deleteRemoteBook(book);
      expect(await cloudMarker(sanitizeTtuFilename('Re:Zero')), isNotNull);
      expect(
        (await db.getSyncDeletionTombstones()).single.itemKey,
        sanitizeTtuFilename('Re:Zero'),
      );
    });

    test('墓碑写不进云盘 → 整体失败，书文件夹原样保留', () async {
      await _seedCloudBook(store, 'Book A');
      final CloudRemoteBookClient c = client();
      final RemoteBookInfo a = await listed(c, 'Book A');
      backend.putJsonError = SyncBackendError('quota');

      await expectLater(
        c.deleteRemoteBook(a),
        throwsA(isA<SyncBackendError>()),
      );
      expect(
        (await _allPaths(
          store,
          'root',
        )).where((String p) => p.startsWith('root/Book A/')),
        hasLength(5),
      );
      expect(await db.getSyncDeletionTombstones(), isEmpty);
    });

    test('文件夹删除失败 → 如实抛出（不假装删成功），墓碑已在、可重试', () async {
      await _seedCloudBook(store, 'Book A');
      final CloudRemoteBookClient c = client();
      final RemoteBookInfo a = await listed(c, 'Book A');
      backend.deleteError = SyncBackendError('403');

      await expectLater(
        c.deleteRemoteBook(a),
        throwsA(isA<SyncBackendError>()),
      );
      expect(await cloudMarker('Book A'), isNotNull);

      backend.deleteError = null;
      await c.deleteRemoteBook(a);
      expect(
        (await _allPaths(
          store,
          'root',
        )).where((String p) => p.startsWith('root/Book A')),
        isEmpty,
      );
    });

    test('没有本机库（只读场景构造的客户端）→ 拒绝执行，云盘不动', () async {
      await _seedCloudBook(store, 'Book A');
      final CloudRemoteBookClient c = client(withDb: false);
      final RemoteBookInfo a = await listed(c, 'Book A');
      await expectLater(c.deleteRemoteBook(a), throwsStateError);
      expect(await cloudMarker('Book A'), isNull);
    });
  });

  group('probeRemoteReachability', () {
    test('列得到同步根 → reachable', () async {
      expect(
        await client().probeRemoteReachability(),
        RemoteSourceReachability.reachable,
      );
    });

    test('后端连不上 → unreachable', () async {
      backend.listChildrenError = SyncBackendError(
        'timeout',
        isRetryable: true,
      );
      expect(
        await client().probeRemoteReachability(),
        RemoteSourceReachability.unreachable,
      );
    });

    test('登录失效 → credentialRejected', () async {
      backend.listChildrenError = SyncAuthError('expired');
      expect(
        await client().probeRemoteReachability(),
        RemoteSourceReachability.credentialRejected,
      );
    });
  });

  group('其它设备下一轮同步不会把它拉回来', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('cloud_delete_other');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    SyncOrchestrator otherDevice(FushiDatabase otherDb) => SyncOrchestrator(
      db: otherDb,
      backend: backend,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncMangaContent: false,
      syncAudioBookFiles: false,
      syncDictionary: false,
    );

    Future<void> insertLocalBook(
      FushiDatabase otherDb,
      String title, {
      required int localAddedAt,
    }) async {
      await otherDb.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: sanitizeTtuFilename(title),
          title: title,
          epubPath: '${tmp.path}/$title.epub',
          extractDir: '${tmp.path}/$title',
          chapterCount: 1,
          chaptersJson: '["c"]',
          importedAt: localAddedAt,
          localAddedAt: Value<int?>(localAddedAt),
        ),
      );
    }

    test('持有旧副本的设备：不重建书文件夹，收到「其他设备已删除」候选；别的书照常同步', () async {
      final FushiDatabase other = _memDb();
      addTearDown(other.close);
      await insertLocalBook(other, 'Book A', localAddedAt: 1000);
      await insertLocalBook(other, 'Book C', localAddedAt: 1000);
      await _seedCloudBook(store, 'Book A');
      await _seedCloudBook(store, 'Book C');

      // 本机（只有远端占位卡）从云盘删掉 Book A。
      final CloudRemoteBookClient c = client();
      await c.deleteRemoteBook(await listed(c, 'Book A'));
      backend.ensuredBookFolders.clear();

      final SyncRunReport report = await otherDevice(other).run();

      expect(
        report.errors.where((String e) => e.startsWith('books')),
        isEmpty,
        reason: '书阶段必须完整跑完，下面的「没建 Book A」才有意义',
      );
      expect(backend.ensuredBookFolders, <String>['Book C']);
      expect(
        (await store.listChildren('root')).map((AssetEntry e) => e.name),
        isNot(contains('Book A')),
        reason: '被删的书文件夹不能被持有旧副本的设备建回云盘',
      );
      expect(
        report.deletionCandidates.map(
          (DeletionPropagationCandidate c) => (c.mediaType, c.itemKey),
        ),
        contains((SyncTombstoneKind.book.dbValue, 'Book A')),
      );
    });

    test('删除之后才在那台设备上重新加入的书：照常同步（新的加入意图）', () async {
      await _seedCloudBook(store, 'Book A');
      final CloudRemoteBookClient c = client();
      await c.deleteRemoteBook(await listed(c, 'Book A'));
      final int deletedAt =
          (await db.getSyncDeletionTombstones()).single.deletedAt;
      backend.ensuredBookFolders.clear();

      final FushiDatabase other = _memDb();
      addTearDown(other.close);
      await insertLocalBook(other, 'Book A', localAddedAt: deletedAt + 1);

      final SyncRunReport report = await otherDevice(other).run();
      expect(report.errors.where((String e) => e.startsWith('books')), isEmpty);
      expect(backend.ensuredBookFolders, <String>['Book A']);
      expect(report.deletionCandidates, isEmpty);
    });
  });
}
