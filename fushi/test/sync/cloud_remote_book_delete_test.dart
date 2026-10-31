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
/// 4. 「从所有设备删除」本机有副本时，云通道发布墓碑的同时删掉云盘上的书文件夹
///    （所有者 2026-10-31 拍板），删失败不标「已发布」、下一轮重试。
/// 5. **删了再重新导入不会被自动删掉**（所有者问「删了我重新导入以后不会自动给我删除
///    吧」）：墓碑按「键 + deletedAt」只管 deletedAt 之前就在的那份；重新导入（同名、
///    同 bookKey、同文件夹名）的 `localAddedAt` 是导入时刻，本机与其它设备都把它当新
///    书——不弹删除确认、照常上传、别的设备看得见也下得到；只有删除前就有旧副本的设备
///    仍收到（只针对旧那份的）删除确认。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/cloud_remote_book_client.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_deletion_filter.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
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
        expect(row.cloudFolderName, 'Book A');
        expect(
          TombstoneCloudFolderState.fromDb(row.cloudFolderState),
          TombstoneCloudFolderState.deleted,
        );
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
      final SyncDeletionTombstoneRow pending =
          (await db.getSyncDeletionTombstones()).single;
      expect(pending.cloudFolderName, 'Book A');
      expect(
        TombstoneCloudFolderState.fromDb(pending.cloudFolderState),
        TombstoneCloudFolderState.pending,
        reason: '文件夹没删掉就不能记成已处置',
      );
      expect(
        await loadPendingRemoteDeletionKeys(
          db,
          SyncTombstoneKind.book,
          remoteLibrarySourceId: cloudRemoteLibrarySourceId(
            SyncBackendType.webDav.name,
          ),
        ),
        contains('Book A'),
        reason: '残留还在云盘上，书架继续藏',
      );

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

  group('「从所有设备删除」本机有副本：发布墓碑时一并删掉云盘书文件夹', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('cloud_delete_everywhere');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    SyncOrchestrator device(FushiDatabase deviceDb) => SyncOrchestrator(
      db: deviceDb,
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

    /// 本机导入一本书。[localAddedAt] 省略 = 生产导入路径的默认值（导入时刻，
    /// `insertEpubBook` 填 now）。
    Future<void> importBook(
      FushiDatabase deviceDb,
      String title, {
      int? localAddedAt,
    }) async {
      await deviceDb.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: sanitizeTtuFilename(title),
          title: title,
          epubPath: '${tmp.path}/$title.epub',
          extractDir: '${tmp.path}/$title',
          chapterCount: 1,
          chaptersJson: '["c"]',
          importedAt: 1,
          localAddedAt: localAddedAt == null
              ? const Value<int?>.absent()
              : Value<int?>(localAddedAt),
        ),
      );
    }

    /// 书架「从所有设备删除」落到库里的两步（`ReaderFushiSource.deleteBook`，
    /// scope = syncEverywhere）：删行（带备份墓碑）+ 记同步删除墓碑。
    Future<int> deleteEverywhere(FushiDatabase deviceDb, String title) async {
      final String key = sanitizeTtuFilename(title);
      expect(await deviceDb.deleteEpubBook(key, tombstone: true), 1);
      final int deletedAt = DateTime.now().millisecondsSinceEpoch;
      await deviceDb.writeSyncDeletionTombstone(
        SyncTombstoneKind.book.dbValue,
        key,
        deletedAt,
        cloudFolderName: sanitizeTtuFilename(title),
      );
      return deletedAt;
    }

    Future<SyncDeletionTombstoneRow> tombstoneOf(
      FushiDatabase deviceDb,
      String itemKey,
    ) async => (await deviceDb.getSyncDeletionTombstones()).singleWhere(
      (SyncDeletionTombstoneRow r) => r.itemKey == itemKey,
    );

    Future<Set<String>> cloudFolders() async => <String>{
      for (final AssetEntry e in await store.listChildren('root'))
        if (e.isFolder && !isReservedSyncFolderName(e.name)) e.name,
    };

    Future<Set<String>> hiddenOnShelf(FushiDatabase deviceDb) =>
        loadPendingRemoteDeletionKeys(
          deviceDb,
          SyncTombstoneKind.book,
          remoteLibrarySourceId: cloudRemoteLibrarySourceId(
            SyncBackendType.webDav.name,
          ),
        );

    Iterable<String> candidateKeys(SyncRunReport r) => <String>[
      for (final DeletionPropagationCandidate c in r.deletionCandidates)
        if (c.mediaType == SyncTombstoneKind.book.dbValue) c.itemKey,
    ];

    test('同步一轮：先写墓碑、再删书文件夹，标为已发布；别的书不动', () async {
      await _seedCloudBook(store, 'Book A');
      await _seedCloudBook(store, 'Book C');
      await importBook(db, 'Book A', localAddedAt: 1000);
      await importBook(db, 'Book C', localAddedAt: 1000);
      final int deletedAt = await deleteEverywhere(db, 'Book A');
      expect(await hiddenOnShelf(db), <String>{'Book A'}, reason: '残留还在，先藏着');

      final SyncRunReport report = await device(db).run();

      expect(
        report.errors.where((String e) => e.contains('tombstone')),
        isEmpty,
      );
      expect(await cloudFolders(), <String>{'Book C'});
      expect(
        parseDeletionTombstoneJson(await cloudMarker('Book A'))?.deletedAt,
        deletedAt,
      );
      expect(
        (await db.getSyncDeletionTombstones()).single.remotePublishedAt,
        greaterThan(0),
      );
      expect(
        TombstoneCloudFolderState.fromDb(
          (await tombstoneOf(db, 'Book A')).cloudFolderState,
        ),
        TombstoneCloudFolderState.deleted,
      );
      expect(await hiddenOnShelf(db), isEmpty, reason: '文件夹已删，不再需要藏');
    });

    test('墓碑键是对端键 / 别名（≠ 文件夹名）：按删除时记下的文件夹名删掉', () async {
      await _seedCloudBook(store, 'Re:Zero');
      await _seedCloudBook(store, 'Book C');
      // 从对端下载、落地键与对端不同的书：墓碑写对端键（`syncDeletionBookKeyOf`），
      // 云盘文件夹名是 sanitizeTtuFilename(书名)，两者对不上。
      await db.writeSyncDeletionTombstone(
        SyncTombstoneKind.book.dbValue,
        'peer-key-7',
        DateTime.now().millisecondsSinceEpoch,
        cloudFolderName: sanitizeTtuFilename('Re:Zero'),
      );
      expect(await hiddenOnShelf(db), <String>{
        'peer-key-7',
        sanitizeTtuFilename('Re:Zero'),
      }, reason: '书架按文件夹名比对：处置前两者都藏');

      final SyncRunReport report = await device(db).run();

      expect(
        report.errors.where((String e) => e.contains('tombstone')),
        isEmpty,
      );
      expect(await cloudFolders(), <String>{
        'Book C',
      }, reason: '旧实现按墓碑键找文件夹，找不到就静默跳过，残留永远留在云盘');
      final SyncDeletionTombstoneRow row = await tombstoneOf(db, 'peer-key-7');
      expect(row.remotePublishedAt, greaterThan(0));
      expect(
        TombstoneCloudFolderState.fromDb(row.cloudFolderState),
        TombstoneCloudFolderState.deleted,
      );
      expect(await cloudMarker('peer-key-7'), isNotNull);
      expect(await hiddenOnShelf(db), isEmpty);
    });

    test('云盘上本就没有这本书的文件夹：记「本就没有」而不是「已删」，墓碑照常发布', () async {
      await _seedCloudBook(store, 'Book C');
      await importBook(db, 'Never Uploaded', localAddedAt: 1000);
      await deleteEverywhere(db, 'Never Uploaded');

      final SyncRunReport report = await device(db).run();

      expect(
        report.errors.where((String e) => e.contains('tombstone')),
        isEmpty,
      );
      expect(await cloudFolders(), <String>{'Book C'}, reason: '别的书不动');
      final SyncDeletionTombstoneRow row = await tombstoneOf(
        db,
        'Never Uploaded',
      );
      expect(row.remotePublishedAt, greaterThan(0));
      expect(
        TombstoneCloudFolderState.fromDb(row.cloudFolderState),
        TombstoneCloudFolderState.absent,
      );
      expect(await hiddenOnShelf(db), isEmpty);
    });

    test('升级前的已发布墓碑（没记文件夹名）：同步不删任何文件夹，书架继续藏', () async {
      // 旧版本「从所有设备删除」：墓碑已发布，但从没删过云盘文件夹。
      await _seedCloudBook(store, 'Legacy');
      await db.writeSyncDeletionTombstone(
        SyncTombstoneKind.book.dbValue,
        'Legacy',
        100,
      );
      await db.markSyncDeletionPublished(
        SyncTombstoneKind.book.dbValue,
        'Legacy',
        200,
      );
      expect(await hiddenOnShelf(db), <String>{
        'Legacy',
      }, reason: '旧实现把「已发布」当「文件夹已删」，升级后这里会放出整个残留');

      final SyncRunReport report = await device(db).run();

      expect(
        report.errors.where((String e) => e.contains('tombstone')),
        isEmpty,
      );
      expect(
        await cloudFolders(),
        contains('Legacy'),
        reason: '不知道文件夹名就不碰（那之后同名文件夹可能是别人重新上传的新书）',
      );
      expect(
        TombstoneCloudFolderState.fromDb(
          (await tombstoneOf(db, 'Legacy')).cloudFolderState,
        ),
        TombstoneCloudFolderState.pending,
      );
      expect(await hiddenOnShelf(db), <String>{'Legacy'});
    });

    test('书架直删时文件夹删失败：云通道下一轮按记下的文件夹名重试删掉', () async {
      await _seedCloudBook(store, 'Book A');
      final CloudRemoteBookClient c = client();
      backend.deleteError = SyncBackendError('403');
      await expectLater(
        c.deleteRemoteBook(await listed(c, 'Book A')),
        throwsA(isA<SyncBackendError>()),
      );
      backend.deleteError = null;
      expect(await cloudFolders(), contains('Book A'));
      expect(await hiddenOnShelf(db), <String>{'Book A'});

      final SyncRunReport report = await device(db).run();

      expect(
        report.errors.where((String e) => e.contains('tombstone')),
        isEmpty,
      );
      expect(await cloudFolders(), isNot(contains('Book A')));
      expect(
        TombstoneCloudFolderState.fromDb(
          (await tombstoneOf(db, 'Book A')).cloudFolderState,
        ),
        TombstoneCloudFolderState.deleted,
      );
      expect(await hiddenOnShelf(db), isEmpty);
    });

    test('删文件夹失败：墓碑已写、不标已发布、残留继续藏；下一轮重试删掉', () async {
      await _seedCloudBook(store, 'Book A');
      await importBook(db, 'Book A', localAddedAt: 1000);
      await deleteEverywhere(db, 'Book A');
      backend.deleteError = SyncBackendError('403');

      final SyncRunReport first = await device(db).run();
      expect(
        first.errors.where((String e) => e.contains('cloud book folder')),
        hasLength(1),
        reason: '删失败要如实记错，不能假装删成功',
      );
      expect(await cloudMarker('Book A'), isNotNull);
      expect(await cloudFolders(), contains('Book A'));
      expect(
        (await db.getSyncDeletionTombstones()).single.remotePublishedAt,
        0,
      );
      expect(await hiddenOnShelf(db), <String>{'Book A'});

      backend.deleteError = null;
      await device(db).run();
      expect(await cloudFolders(), isNot(contains('Book A')));
      expect(
        (await db.getSyncDeletionTombstones()).single.remotePublishedAt,
        greaterThan(0),
      );
    });

    test('删除 → 重新导入 → 本机与另一台设备各同步一轮：书仍在且已上传；旧副本设备只对旧那份弹确认', () async {
      await _seedCloudBook(store, 'Book A');
      await importBook(db, 'Book A', localAddedAt: 1000);
      final FushiDatabase oldCopy = _memDb();
      addTearDown(oldCopy.close);
      await importBook(oldCopy, 'Book A', localAddedAt: 1000);

      // 本机「从所有设备删除」并同步：墓碑发布、书文件夹删掉。
      final int deletedAt = await deleteEverywhere(db, 'Book A');
      await device(db).run();
      expect(await cloudFolders(), isNot(contains('Book A')));

      // 本机重新导入同一本（同名 → 同 bookKey、同文件夹名）。
      await importBook(db, 'Book A');
      final EpubBookRow reimported = (await db.getAllEpubBooks()).single;
      expect(reimported.localAddedAt, greaterThanOrEqualTo(deletedAt));
      expect(
        await db.getSyncDeletionTombstones(),
        isEmpty,
        reason: '重新入库清掉本机墓碑，不再发布',
      );

      // 本机同步一轮：不弹删除确认、照常上传（推送否决不拦重新导入的书）。
      backend.ensuredBookFolders.clear();
      final SyncRunReport mine = await device(db).run();
      expect(mine.errors.where((String e) => e.startsWith('books')), isEmpty);
      expect(candidateKeys(mine), isEmpty);
      expect(backend.ensuredBookFolders, <String>['Book A']);
      expect(await cloudFolders(), contains('Book A'));
      expect(await db.getAllEpubBooks(), hasLength(1), reason: '本机书仍在');
      expect(
        await cloudMarker('Book A'),
        isNotNull,
        reason: '云盘上旧墓碑仍在——旧副本设备还要靠它收到删除确认',
      );

      // 另一台从没有过这本的设备：书架上看得见（不被藏），下载后同步也不被删。
      final FushiDatabase fresh = _memDb();
      addTearDown(fresh.close);
      expect(await hiddenOnShelf(fresh), isEmpty);
      expect(
        (await client(
          database: fresh,
        ).listRemoteBooks()).map((RemoteBookInfo b) => b.title),
        contains('Book A'),
      );
      await importBook(fresh, 'Book A');
      backend.ensuredBookFolders.clear();
      final SyncRunReport theirs = await device(fresh).run();
      expect(theirs.errors.where((String e) => e.startsWith('books')), isEmpty);
      expect(candidateKeys(theirs), isEmpty);
      expect(backend.ensuredBookFolders, <String>['Book A']);
      expect(await fresh.getAllEpubBooks(), hasLength(1));

      // 删除之前就有旧副本的设备：仍收到删除确认（只针对它那份旧的），也不把旧的推上去。
      backend.ensuredBookFolders.clear();
      final SyncRunReport old = await device(oldCopy).run();
      expect(candidateKeys(old), <String>['Book A']);
      expect(backend.ensuredBookFolders, isEmpty);

      // 再同步一轮本机：仍然不弹、仍在。
      final SyncRunReport again = await device(db).run();
      expect(candidateKeys(again), isEmpty);
      expect(await db.getAllEpubBooks(), hasLength(1));
      expect(await cloudFolders(), contains('Book A'));
    });

    test('别的设备删后重新导入并上传：删除方书架上看得见这本新书（已发布的墓碑不再藏）', () async {
      await _seedCloudBook(store, 'Book A');
      await importBook(db, 'Book A', localAddedAt: 1000);
      await deleteEverywhere(db, 'Book A');
      await device(db).run();

      final FushiDatabase other = _memDb();
      addTearDown(other.close);
      await importBook(other, 'Book A');
      await device(other).run();
      expect(await cloudFolders(), contains('Book A'));

      expect(await hiddenOnShelf(db), isEmpty);
      expect(
        (await client().listRemoteBooks()).map((RemoteBookInfo b) => b.title),
        contains('Book A'),
      );
      // 删除方自己下载这本新书后同步：不弹确认。
      await importBook(db, 'Book A');
      final SyncRunReport r = await device(db).run();
      expect(candidateKeys(r), isEmpty);
    });

    test('书架「同时从远端删除」后重新导入：同样当新书', () async {
      await _seedCloudBook(store, 'Book A');
      final CloudRemoteBookClient c = client();
      await c.deleteRemoteBook(await listed(c, 'Book A'));
      expect(await hiddenOnShelf(db), isEmpty, reason: '文件夹已删、墓碑已发布');

      await importBook(db, 'Book A');
      backend.ensuredBookFolders.clear();
      final SyncRunReport r = await device(db).run();
      expect(candidateKeys(r), isEmpty);
      expect(backend.ensuredBookFolders, <String>['Book A']);
      expect(await db.getAllEpubBooks(), hasLength(1));
    });

    test('媒体服务器等不执行删除的来源：墓碑在就一直藏（行为不变）', () async {
      await db.writeSyncDeletionTombstone(
        SyncTombstoneKind.book.dbValue,
        'K',
        5,
      );
      await db.markSyncDeletionPublished(
        SyncTombstoneKind.book.dbValue,
        'K',
        6,
      );
      expect(
        await loadPendingRemoteDeletionKeys(
          db,
          SyncTombstoneKind.book,
          remoteLibrarySourceId: 'jellyfin:x',
        ),
        <String>{'K'},
      );
    });
  });
}
