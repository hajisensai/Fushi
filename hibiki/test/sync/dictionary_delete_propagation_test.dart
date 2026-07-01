import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/aggregate_snapshot.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Records the namespace/name queried and the id deleted; [present] is what
/// findAsset returns. Everything else throws (must not be touched).
class _RecordingBackend implements SyncBackend {
  _RecordingBackend({this.present});

  final AssetEntry? present;
  String? ensuredNamespace;
  String? queriedName;
  String? deletedId;

  @override
  Future<String> ensureNamespace(String name) async {
    ensuredNamespace = name;
    return 'root/$name/';
  }

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    queriedName = name;
    return present;
  }

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    deletedId = id;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

// ── live 分支集成：验证 HibikiClientSyncBackend 路由到 host DELETE 端点 ─────

class _FakeLibraryService implements HibikiLibraryHostService {
  @override
  Future<AggregateSnapshot> getAggregateSnapshot() async =>
      const AggregateSnapshot();

  @override
  Future<void> applyAggregateSnapshot(AggregateSnapshot snapshot) async {}

  final List<String> deleted = <String>[];

  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async =>
      <RemoteDictionaryInfo>[];

  @override
  Future<File> exportDictionary(String name) async =>
      throw UnimplementedError('export not needed in this test');

  @override
  Future<void> importDictionary(File packageFile) async =>
      throw UnimplementedError('import not needed in this test');

  @override
  Future<void> deleteDictionary(String name) async => deleted.add(name);

  // ── books stubs ────────────────────────────────────────────────────────────
  @override
  Future<List<RemoteBookInfo>> listBooks() async => <RemoteBookInfo>[];

  @override
  Future<File> exportBook(String title) async =>
      throw UnimplementedError('export not needed in this test');

  @override
  Future<void> importBook(File epubFile) async {}

  @override
  Future<void> deleteBook(String title) async {}

  final Map<String, RemoteBookProgress> bookProgress =
      <String, RemoteBookProgress>{};

  @override
  Future<RemoteBookProgress> getBookProgress(String bookKey) async =>
      bookProgress[bookKey] ?? RemoteBookProgress.empty;

  @override
  Future<void> putBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    final RemoteBookProgress current =
        bookProgress[bookKey] ?? RemoteBookProgress.empty;
    bookProgress[bookKey] =
        resolveBookProgressSync(local: current, remote: progress);
  }

  // ── local audio stubs ──────────────────────────────────────────────────────
  @override
  Future<List<RemoteLocalAudioInfo>> listLocalAudio() async =>
      <RemoteLocalAudioInfo>[];

  @override
  Future<File> exportLocalAudio(String displayName) async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<void> importLocalAudio(File packageFile) async {}

  @override
  Future<void> deleteLocalAudio(String displayName) async {}

  // ── audiobook stubs ────────────────────────────────────────────────────────
  @override
  Future<List<RemoteAudiobookInfo>> listAudiobooks() async =>
      <RemoteAudiobookInfo>[];

  @override
  Future<File> exportAudiobook(String bookKey) async =>
      throw UnimplementedError('not used in this test');

  @override
  Future<bool> audiobookExists(String bookKey) async => false;

  @override
  Future<void> importAudiobook(File packageFile,
      {String? bookKeyOverride}) async {}

  @override
  Future<void> deleteAudiobook(String bookKey) async {}

  // ── video stubs (P4-1) ────────────────────────────────────────────────────
  @override
  Future<List<RemoteVideoInfo>> listVideos() async => <RemoteVideoInfo>[];

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      null;

  @override
  Future<File?> resolveVideoSubtitle(String id,
          {String langCode = 'ja', int episodeIndex = 0}) async =>
      null;

  @override
  Future<({int positionMs, int updatedAtMs})> getAudiobookPosition(
    String bookKey,
  ) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putAudiobookPosition(
    String bookKey,
    int positionMs,
    int updatedAtMs,
  ) async {}

  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}
}

HibikiDatabase _memDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 构造一个已认证的 HibikiClientSyncBackend，指向给定 base url。
Future<HibikiClientSyncBackend> _buildBackend({
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
      HibikiClientSyncBackend.withProbe((String url, String tok) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

void main() {
  group('deleteRemoteDictionaryAsset (BUG-086)', () {
    test('deletes the matching <name>.hibikidict package and reports true',
        () async {
      final _RecordingBackend backend = _RecordingBackend(
        present: const AssetEntry(id: 'asset-1', name: 'Genius.hibikidict'),
      );

      final bool deleted = await deleteRemoteDictionaryAsset(backend, 'Genius');

      expect(deleted, isTrue);
      expect(backend.ensuredNamespace, kSyncDictionaryNamespace);
      expect(backend.queriedName, 'Genius.hibikidict',
          reason: 'must look up the package by name + .hibikidict suffix');
      expect(backend.deletedId, 'asset-1',
          reason: 'must delete the exact remote package found');
    });

    test('no-op (false) when the remote package is absent', () async {
      final _RecordingBackend backend = _RecordingBackend(present: null);

      final bool deleted =
          await deleteRemoteDictionaryAsset(backend, 'Missing');

      expect(deleted, isFalse);
      expect(backend.deletedId, isNull,
          reason: 'nothing to delete → deleteAsset must not be called');
    });
  });

  group('删除传播 live 分支（Task-6）', () {
    /// 验证当 backend 是 HibikiClientSyncBackend 时，deleteRemoteDictionary
    /// 确实向 host 发送 DELETE /api/library/dictionaries/<name>，
    /// 且 host 库服务记录到该删除——不经过暂存 deleteRemoteDictionaryAsset 路径。
    test(
        'HibikiClientSyncBackend.deleteRemoteDictionary routes to host DELETE endpoint',
        () async {
      const String token = 'test-token-propagate';
      final _FakeLibraryService lib = _FakeLibraryService();
      final HibikiSyncServer server = HibikiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_del_prop').path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: lib,
      );
      await server.start();
      addTearDown(server.stop);

      final HibikiClientSyncBackend backend = await _buildBackend(
        base: 'http://127.0.0.1:${server.port}',
        token: token,
      );

      // 直接调 live 方法——这正是分流分支（backend is HibikiClientSyncBackend）
      // 在 _propagateDictionaryDeleteToRemote 中执行的代码路径。
      await backend.deleteRemoteDictionary('Genius');

      expect(lib.deleted, contains('Genius'),
          reason: 'host 库服务必须收到删除，验证 live DELETE 端点而非暂存路径');
    });
  });
}
