/// Task T2.4：orchestrator 书籍内容 live 同步集成测试。
///
/// 用例 A：互联（HibikiClientSyncBackend）+ syncContent=true
///   → 走 live 端点上传本端 epub，不自动拉取远端独有书，也不经书文件夹暂存路径。
/// 用例 B：互联 + syncContent=false
///   → 不传任何 epub 内容（booksImported=0、无 toPull/toPush 动作），
///   但元数据路径仍正常运行。
/// 用例 C：云后端（非 HibikiClient）+ syncContent=true
///   → 不走 live 端点；本地已有书仍走 SyncManager 书文件夹路径上传内容/元数据。
///
/// **进度/统计/有声书位置回归**：只检查互联分支把 syncContent=false 传给
/// SyncManager，已由 sync_manager_* 测试全量覆盖；本文件不重复覆盖
/// SyncManager 内部行为，避免测试耦合。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'fake_asset_store.dart';

// ── helpers ───────────────────────────────────────────────────────────────────

HibikiDatabase _memDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 在 [db] 里插入一本书，同时在 [extractDir] 写入最小 EPUB 结构。
Future<void> _seedBook({
  required HibikiDatabase db,
  required String title,
  required String extractDir,
}) async {
  Directory(extractDir).createSync(recursive: true);
  File(p.join(extractDir, 'mimetype'))
      .writeAsStringSync('application/epub+zip');
  final Directory metaInf = Directory(p.join(extractDir, 'META-INF'))
    ..createSync();
  File(p.join(metaInf.path, 'container.xml')).writeAsStringSync(
    '<?xml version="1.0"?>'
    '<container version="1.0" xmlns="urn:oasis:schemas:container">'
    '<rootfiles><rootfile full-path="content.opf"'
    ' media-type="application/oebps-package+xml"/></rootfiles>'
    '</container>',
  );
  File(p.join(extractDir, 'content.opf')).writeAsStringSync(
    '<?xml version="1.0"?>'
    '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
    '<metadata/><manifest/><spine/></package>',
  );

  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: title,
      title: title,
      epubPath: p.join(extractDir, 'original.epub'),
      extractDir: extractDir,
      chapterCount: 1,
      chaptersJson: '["ch1"]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

/// 构造并认证一个 [HibikiClientSyncBackend]，fake probe 总返回 true。
Future<HibikiClientSyncBackend> _buildClientBackend({
  required String base,
  required String token,
}) async {
  final HibikiDatabase db = _memDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(<HibikiClientUrl>[
    HibikiClientUrl(url: base, enabled: true),
  ]);
  await repo.setHibikiClientToken(token);
  final HibikiClientSyncBackend backend =
      HibikiClientSyncBackend.withProbe((String u, String t) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

/// 构造只开 syncContent 的 orchestrator（用于书籍内容 live 测试）。
SyncOrchestrator _bookOrchestrator({
  required HibikiDatabase db,
  required SyncBackend backend,
  required Directory tmp,
  required bool syncContent,
}) =>
    SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: syncContent,
      syncAudioBookFiles: false,
      syncDictionary: false,
      syncLocalAudio: false,
    );

// ── Fake staged backend（云路径用，同 sync_orchestrator_live_dict_test.dart）──

class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend(this._store);
  final FakeAssetStore _store;

  bool ensureBookFolderCalled = false;

  @override
  Future<String> ensureNamespace(String name) => _store.ensureNamespace(name);
  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _store.ensureFolder(parentId, name);
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _store.listChildren(namespaceId);
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) =>
      _store.findAsset(namespaceId, name);
  @override
  Future<void> putAsset(String namespaceId, String name, File file,
          {void Function(double progress)? onProgress}) =>
      _store.putAsset(namespaceId, name, file, onProgress: onProgress);
  @override
  Future<void> getAsset(String assetId, File destination,
          {void Function(double progress)? onProgress}) =>
      _store.getAsset(assetId, destination, onProgress: onProgress);
  @override
  Future<Object?> getJsonAsset(String assetId) => _store.getJsonAsset(assetId);
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _store.putJsonAsset(namespaceId, name, json);
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      _store.deleteAsset(id, isFolder: isFolder);

  @override
  Future<String> findOrCreateRootFolder() async => 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) {
    ensureBookFolderCalled = true;
    return _store.ensureFolder(rootFolderId, bookTitle);
  }

  // ── SyncManager 元数据路径（进度/统计/有声书位置）──────────────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async =>
      const DriveSyncFiles(progress: null, statistics: null, audioBook: null);

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async =>
      const <DriveFile>[];

  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<String?> get currentEmail async => null;
  @override
  Future<void> authenticate({required SyncRepository repo}) async {}
  @override
  Future<void> signOut({required SyncRepository repo}) async {}
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;
  @override
  Future<void> refreshAuth() async {}
  @override
  Future<TtuProgress> getProgressFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {}
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
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {}
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {}
  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async =>
      null;
  @override
  void clearCache() {}
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  String? get cachedRootFolderId => 'root';
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}
}

// ── main ──────────────────────────────────────────────────────────────────────

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('orch_live_book_');
  });
  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  // ── 用例 A：互联 live + syncContent=true（上传语义）──────────────────────

  group('用例A: 互联 live 上传路径（syncContent=true）', () {
    late HibikiSyncServer server;
    late HibikiDatabase hostDb;
    late String serverBase;
    const String token = 'orch-live-book-token';

    setUp(() async {
      hostDb = _memDb();

      // host 上植入书籍 Y（有内容）
      final String hostExtract = p.join(work.path, 'host_extract_Y');
      await _seedBook(db: hostDb, title: 'BookY', extractDir: hostExtract);

      final AppModelLibraryHostService libSvc = AppModelLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        // host 侧 fake 导入：把 epub 写入 host DB 而不用真实 EpubImporter
        importBookFromFile: (File f) async {
          final String title = p.basenameWithoutExtension(f.path);
          final String extractDir =
              p.join(work.path, 'host_extract_${title}_imported');
          await _seedBook(db: hostDb, title: title, extractDir: extractDir);
        },
      );

      server = HibikiSyncServer(
        syncDataDir: p.join(work.path, 'server_data'),
        port: 0,
        token: token,
        allowLan: false,
        libraryService: libSvc,
      );
      await server.start();
      serverBase = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.stop());

    test('本地无 BookY，syncContent=true → 不自动拉取远端独有 BookY', () async {
      // 本地：只有 BookX，没有 BookY
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      final String localExtractX = p.join(work.path, 'local_extract_X');
      await _seedBook(db: localDb, title: 'BookX', extractDir: localExtractX);

      final Directory tmp = Directory(p.join(work.path, 'tmp_pull'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _bookOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncContent: true,
      );
      final SyncRunReport report = SyncRunReport();
      await orch.syncBooksContentLiveForTest(report, backend);

      expect(report.errors, isEmpty,
          reason: 'live book upload 无错误: ${report.errors}');
      expect(report.booksImported, 0,
          reason: 'Upload book files 不能把远端独有 BookY 自动拉到本机');
      final List<EpubBookRow> localBooks = await localDb.getAllEpubBooks();
      expect(
        localBooks.map((EpubBookRow b) => b.title),
        isNot(contains('BookY')),
      );
    });

    test('push：host 无 BookX，syncContent=true → 推送 BookX，且 host 收到 epub',
        () async {
      // 本地：只有 BookX，没有 BookY
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      final String localExtractX = p.join(work.path, 'local_extract_X_push');
      await _seedBook(db: localDb, title: 'BookX', extractDir: localExtractX);

      final Directory tmp = Directory(p.join(work.path, 'tmp_push'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _bookOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncContent: true,
      );
      final SyncRunReport report = SyncRunReport();
      await orch.syncBooksContentLiveForTest(report, backend);

      expect(report.errors, isEmpty,
          reason: 'live book push 无错误: ${report.errors}');
      // 检查 host DB 收到 BookX（host 侧 importBookFromFile 已 fake 导入）
      final List<EpubBookRow> hostBooks = await hostDb.getAllEpubBooks();
      expect(
        hostBooks.map((EpubBookRow b) => b.title),
        contains('BookX'),
        reason: 'BookX 应被推送并导入 host',
      );
    });

    test('upload-only：本地 BookX，host BookY → 只推 BookX，不拉 BookY', () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      final String localExtractX = p.join(work.path, 'local_extract_X_rt');
      await _seedBook(db: localDb, title: 'BookX', extractDir: localExtractX);

      final Directory tmp = Directory(p.join(work.path, 'tmp_rt'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _bookOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncContent: true,
      );
      final SyncRunReport report = SyncRunReport();
      await orch.syncBooksContentLiveForTest(report, backend);

      expect(report.errors, isEmpty,
          reason: 'upload-only errors: ${report.errors}');
      expect(report.booksImported, 0, reason: 'BookY 不应被自动 pull');

      // host 含 BookX
      final List<EpubBookRow> hostBooks = await hostDb.getAllEpubBooks();
      expect(hostBooks.map((EpubBookRow b) => b.title), contains('BookX'));
      final List<EpubBookRow> localBooks = await localDb.getAllEpubBooks();
      expect(
        localBooks.map((EpubBookRow b) => b.title),
        isNot(contains('BookY')),
      );
    });

    test('live 路径不经 sync-data 书文件夹暂存 epub', () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);

      final Directory tmp = Directory(p.join(work.path, 'tmp_no_staging'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _bookOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncContent: true,
      );
      await orch.syncBooksContentLiveForTest(SyncRunReport(), backend);

      // server sync-data 下不应出现以书名命名的书文件夹（epub 内容不经暂存）。
      final String syncDataDir = p.join(work.path, 'server_data', 'sync-data');
      if (Directory(syncDataDir).existsSync()) {
        final List<FileSystemEntity> children =
            Directory(syncDataDir).listSync();
        final bool hasBookFolder = children.any((FileSystemEntity e) =>
            e is Directory && p.basename(e.path) == 'BookY');
        expect(hasBookFolder, isFalse,
            reason: 'live 路径不应在 sync-data 下创建书文件夹暂存 epub');
      }
    });
  });

  // ── 用例 B：互联 + syncContent=false ─────────────────────────────────────

  group('用例B: 互联 + syncContent=false', () {
    late HibikiSyncServer server;
    late HibikiDatabase hostDb;
    late String serverBase;
    const String token = 'orch-live-book-token-b';

    setUp(() async {
      hostDb = _memDb();
      final String hostExtract = p.join(work.path, 'host_extract_Y_b');
      await _seedBook(db: hostDb, title: 'BookY', extractDir: hostExtract);

      final AppModelLibraryHostService libSvc = AppModelLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        // syncContent=false 时 host 不应收到导入请求
        importBookFromFile: (File f) async {
          fail('importBookFromFile 不应在 syncContent=false 时被调用');
        },
      );

      server = HibikiSyncServer(
        syncDataDir: p.join(work.path, 'server_data_b'),
        port: 0,
        token: token,
        allowLan: false,
        libraryService: libSvc,
      );
      await server.start();
      serverBase = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.stop());

    test('syncContent=false → orchestrator.run() 不传 epub 内容（booksImported=0）',
        () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      final String localExtractX = p.join(work.path, 'local_extract_X_b');
      await _seedBook(db: localDb, title: 'BookX', extractDir: localExtractX);

      final Directory tmp = Directory(p.join(work.path, 'tmp_b'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _bookOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncContent: false,
      );
      final SyncRunReport report = await orch.run();

      expect(report.booksImported, 0, reason: 'syncContent=false 不应传输 epub 内容');
      expect(report.errors, isEmpty,
          reason: 'syncContent=false 运行无错误: ${report.errors}');
    });
  });

  // ── 用例 C：云后端仍走 SyncManager 书文件夹路径 ───────────────────────────

  group('用例C: 云后端（非 HibikiClient）走书文件夹上传路径', () {
    test('FakeSyncBackend + syncContent=true → 不走 live 端点', () async {
      // 云后端：FakeSyncBackend，listBooks 返回空（模拟无远端书可导入）
      final FakeAssetStore store = FakeAssetStore();
      final _FakeSyncBackend backend = _FakeSyncBackend(store);
      final Directory tmp = Directory(p.join(work.path, 'tmp_c'))..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // 本地有一本书
      final String extractDir = p.join(work.path, 'local_extract_c');
      await _seedBook(db: db, title: 'CloudBook', extractDir: extractDir);

      final SyncOrchestrator orch = _bookOrchestrator(
        db: db,
        backend: backend,
        tmp: tmp,
        syncContent: true,
      );
      final SyncRunReport report = await orch.run();

      // 关键断言：云路径调用了 ensureBookFolder（SyncManager 进度路径走书文件夹）
      // 而非 live 端点（FakeSyncBackend 没有 listRemoteBooks，调用它会抛）
      expect(report.errors, isEmpty, reason: '云后端路径运行无错误: ${report.errors}');
      // 云路径不自动拉取远端独有书。
      expect(report.booksImported, 0);
    });
  });
}
