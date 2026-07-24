import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';

import 'helpers/fake_library_host_service.dart';
import 'helpers/live_sync_harness.dart';

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
//
// 共享的 [HibikiLibraryHostService] 存根上移到 [FakeLibraryHostServiceBase]；本文件
// 只关心词典删除是否落到 host，故只 override deleteDictionary 记录调用。

class _FakeLibraryService extends FakeLibraryHostServiceBase {
  final List<String> deleted = <String>[];

  @override
  Future<void> deleteDictionary(String name) async => deleted.add(name);
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

      final HibikiClientSyncBackend backend = await buildHibikiClientBackend(
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
