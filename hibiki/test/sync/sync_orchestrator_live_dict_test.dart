/// Task 5：orchestrator 分流集成测试。
///
/// 用例 A：互联（HibikiClientSyncBackend）走 live 路径——调用 host 的
///   /api/library/dictionaries 端点，绝不创建 __dictionaries__ 文件夹。
/// 用例 B：非 HibikiClient 后端（FakeSyncBackend）仍走 staged 路径——
///   仍会调用 ensureNamespace(__dictionaries__)。
///
/// 词典名使用真实 CJK 名（「明镜」），覆盖 server URI 解码路径。
/// server 端双重解码 bug 已在 hibiki_sync_server.dart 修复（去掉
/// _handleLibraryDictionaries 里多余的 Uri.decodeComponent 调用）。
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

// ── helpers ──────────────────────────────────────────────────────────────────

HibikiDatabase _memDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 在 [db] + [dictRoot] 里建一个名为 [name] 的合法词典（元数据 + 资源文件）。
Future<void> _seedDictionary(
  HibikiDatabase db,
  Directory dictRoot,
  String name,
) async {
  await db.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
    name: name,
    formatKey: 'yomichan',
    order: 0,
    type: const Value('term'),
    metadataJson: const Value('{}'),
    hiddenLanguagesJson: const Value('[]'),
    collapsedLanguagesJson: const Value('[]'),
  ));
  final Directory dir = Directory(p.join(dictRoot.path, name))
    ..createSync(recursive: true);
  File(p.join(dir.path, 'blobs.bin')).writeAsBytesSync(<int>[1, 2, 3]);
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

/// 用 [backend] 构造只开 syncDictionary 的 orchestrator。
SyncOrchestrator _orchestrator(
  HibikiDatabase db,
  SyncBackend backend,
  Directory dictRoot,
  Directory tmp,
) =>
    SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: dictRoot,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncAudioBookFiles: false,
      syncDictionary: true,
      syncLocalAudio: false,
    );

// ── Fake staged backend（同 sync_orchestrator_test.dart 里的 FakeSyncBackend）──

class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend(this._store);
  final FakeAssetStore _store;

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
  }) =>
      _store.ensureFolder(rootFolderId, bookTitle);

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async =>
      throw UnimplementedError();
  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<String?> get currentEmail async => null;
  @override
  Future<void> authenticate({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<void> signOut({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;
  @override
  Future<void> refreshAuth() async {}
  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async =>
      throw UnimplementedError();
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
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async =>
      throw UnimplementedError();
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

  @override
  void evictFolderId(String folderId) {}
}

// ── main ──────────────────────────────────────────────────────────────────────

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('orch_live_dict_');
  });
  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  // ── 用例 A：互联 live（HibikiClientSyncBackend）──────────────────────────

  group('用例A: 互联 live 路径', () {
    late HibikiSyncServer server;
    late HibikiDatabase hostDb;
    late Directory hostDictRoot;
    late String serverBase;
    const String token = 'orch-live-token';

    setUp(() async {
      // host 侧：真实 DB + 资源目录 + AppModelLibraryHostService
      hostDb = _memDb();
      hostDictRoot = Directory(p.join(work.path, 'host_dicts'))..createSync();
      // 在 host 上植入词典「明镜」（CJK 真实词典名，覆盖 server URI 解码路径）
      await _seedDictionary(hostDb, hostDictRoot, '明镜');

      final AppModelLibraryHostService libSvc = AppModelLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: hostDictRoot,
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
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

    test('pull：本地无「明镜」，运行后本地 DB 含「明镜」', () async {
      // 本地：有 JMdict，无「明镜」
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      final Directory localDictRoot =
          Directory(p.join(work.path, 'local_dicts_pull'))..createSync();
      await _seedDictionary(localDb, localDictRoot, 'JMdict');

      final Directory tmp = Directory(p.join(work.path, 'tmp_pull'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch =
          _orchestrator(localDb, backend, localDictRoot, tmp);
      final SyncRunReport report = SyncRunReport();
      await orch.syncDictionaries(report);

      expect(report.errors, isEmpty,
          reason: 'live sync should have no errors: ${report.errors}');
      expect(report.dictionariesImported, 1, reason: '「明镜」应从 host pull 并导入');

      // 本地 DB 现含「明镜」
      final List<DictionaryMetaRow> local =
          await localDb.getAllDictionaryMetadata();
      expect(local.map((DictionaryMetaRow d) => d.name), contains('明镜'));
    });

    test('push：host 无 JMdict，运行后 host DB 含 JMdict', () async {
      // 本地：有 JMdict，无「明镜」
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      final Directory localDictRoot =
          Directory(p.join(work.path, 'local_dicts_push'))..createSync();
      await _seedDictionary(localDb, localDictRoot, 'JMdict');

      final Directory tmp = Directory(p.join(work.path, 'tmp_push'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch =
          _orchestrator(localDb, backend, localDictRoot, tmp);
      final SyncRunReport report = SyncRunReport();
      await orch.syncDictionaries(report);

      expect(report.errors, isEmpty, reason: 'push errors: ${report.errors}');
      expect(report.dictionariesExported, 1, reason: 'JMdict 应推送到 host');

      // host DB 现含 JMdict
      final List<DictionaryMetaRow> hostDicts =
          await hostDb.getAllDictionaryMetadata();
      expect(
          hostDicts.map((DictionaryMetaRow d) => d.name), contains('JMdict'));
    });

    test('live 路径不创建 __dictionaries__ 文件夹', () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      final Directory localDictRoot =
          Directory(p.join(work.path, 'local_dicts_ns'))..createSync();

      final Directory tmp = Directory(p.join(work.path, 'tmp'))..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch =
          _orchestrator(localDb, backend, localDictRoot, tmp);
      await orch.syncDictionaries(SyncRunReport());

      // server 的 sync-data 目录下不应有 __dictionaries__ 文件夹
      final String syncDataDir = p.join(work.path, 'server_data', 'sync-data');
      final Directory dictNs =
          Directory(p.join(syncDataDir, '__dictionaries__'));
      expect(dictNs.existsSync(), isFalse,
          reason: 'live 路径不应在服务端创建 __dictionaries__ 暂存');
    });

    test('pull+push 双向 union round-trip', () async {
      // 本地：JMdict；host：「明镜」。运行后本地含「明镜」，host 含 JMdict。
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);
      final Directory localDictRoot =
          Directory(p.join(work.path, 'local_dicts_rt'))..createSync();
      await _seedDictionary(localDb, localDictRoot, 'JMdict');

      final Directory tmp = Directory(p.join(work.path, 'tmp_rt'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch =
          _orchestrator(localDb, backend, localDictRoot, tmp);
      final SyncRunReport report = SyncRunReport();
      await orch.syncDictionaries(report);

      expect(report.errors, isEmpty,
          reason: 'round-trip errors: ${report.errors}');
      expect(report.dictionariesImported, 1, reason: '「明镜」应 pull');
      expect(report.dictionariesExported, 1, reason: 'JMdict 应 push');

      // 本地现有「明镜」
      final List<DictionaryMetaRow> localDicts =
          await localDb.getAllDictionaryMetadata();
      expect(localDicts.map((DictionaryMetaRow d) => d.name), contains('明镜'));

      // host 有「JMdict」
      final List<DictionaryMetaRow> hostDicts =
          await hostDb.getAllDictionaryMetadata();
      expect(
          hostDicts.map((DictionaryMetaRow d) => d.name), contains('JMdict'));

      // 无暂存目录
      final String syncDataDir = p.join(work.path, 'server_data', 'sync-data');
      expect(
        Directory(p.join(syncDataDir, '__dictionaries__')).existsSync(),
        isFalse,
        reason: '双向 live sync 不应产生暂存',
      );
    });
  });

  // ── 用例 B：非 HibikiClient 后端仍走 staged 路径 ──────────────────────────

  group('用例B: 非互联后端走 staged 路径', () {
    test('FakeSyncBackend 调用 ensureNamespace(__dictionaries__)', () async {
      final FakeAssetStore store = FakeAssetStore();
      final _FakeSyncBackend backend = _FakeSyncBackend(store);
      final Directory tmp = Directory(p.join(work.path, 'tmp'))..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      await _seedDictionary(
          db, Directory(p.join(work.path, 'dicts'))..createSync(), 'JMdict');

      final SyncOrchestrator orch = _orchestrator(
        db,
        backend,
        Directory(p.join(work.path, 'dicts')),
        tmp,
      );
      final SyncRunReport report = SyncRunReport();
      await orch.syncDictionaries(report);

      // staged 路径会 push 词典到 __dictionaries__ 暂存命名空间
      expect(report.dictionariesExported, 1, reason: '非互联后端应走 staged 路径 push');
      expect(report.errors, isEmpty);

      // 验证 __dictionaries__ 命名空间确实被创建（staged 路径的特征）
      final String nsId =
          await backend.ensureNamespace(kSyncDictionaryNamespace);
      final List<AssetEntry> children = await backend.listChildren(nsId);
      expect(children.where((AssetEntry e) => !e.isFolder), isNotEmpty,
          reason: 'staged 路径应在 __dictionaries__ 下创建词典资产');
    });
  });
}
