import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';

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
}
