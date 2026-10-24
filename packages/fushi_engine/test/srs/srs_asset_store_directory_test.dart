import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_asset_store_directory.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';
import 'support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000bb';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fushi_srs_sync_'));
  tearDown(() => root.deleteSync(recursive: true));

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
    );
  }

  test('两台设备经文件系统同步后端收敛；cursor 文件覆盖不留副本', () async {
    final LocalDirectoryAssetStore backend = LocalDirectoryAssetStore(root);
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    SrsSyncEngine engineOf(SrsDbStore s) => SrsSyncEngine(
      directoryKey: 'test',
      directory: SrsAssetStoreDirectory(store: backend, profileUid: kProfile),
      replica: s,
    );
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '雪',
      },
    );
    for (int i = 0; i < 2; i++) {
      final SrsSyncReport ra = await engineOf(a).syncOnce();
      expect(ra.error, isNull);
      final SrsSyncReport rb = await engineOf(b).syncOnce();
      expect(rb.error, isNull);
    }
    final SrsNoteView? n = await b.note(noteId);
    expect(n!.field(srsLapisFieldId(kProfile, 'Expression')), '雪');
    expect((await b.cardsOfNote(noteId)), hasLength(1));
    final Directory writerDir = Directory(
      '${root.path}${Platform.pathSeparator}$kSrsSyncNamespace'
      '${Platform.pathSeparator}$kProfile${Platform.pathSeparator}${a.writerId}',
    );
    final List<String> names = writerDir
        .listSync()
        .map((FileSystemEntity e) => e.uri.pathSegments.last)
        .toList();
    expect(names.where((String n) => n == srsCursorName), hasLength(1));
    expect(names, contains(srsBatchName(1)));
  });

  group('serverTime', () {
    test('列目录带修改时间时直接用', () async {
      final SrsAssetStoreDirectory dir = SrsAssetStoreDirectory(
        store: LocalDirectoryAssetStore(root),
        profileUid: kProfile,
      );
      expect(await dir.serverTime('w'), isNotNull);
    });

    test('列目录没带时间（FTP 大目录）退到 findAsset', () async {
      final _TimedStore store = _TimedStore(
        LocalDirectoryAssetStore(root),
        listTimes: false,
        findTime: 1234,
      );
      final SrsAssetStoreDirectory dir = SrsAssetStoreDirectory(
        store: store,
        profileUid: kProfile,
      );
      expect(await dir.serverTime('w'), 1234);
    });

    test('两处都拿不到 → null（不拿本机墙钟冒充）', () async {
      final _TimedStore store = _TimedStore(
        LocalDirectoryAssetStore(root),
        listTimes: false,
        findTime: null,
      );
      final SrsAssetStoreDirectory dir = SrsAssetStoreDirectory(
        store: store,
        profileUid: kProfile,
      );
      expect(await dir.serverTime('w'), isNull);
    });
  });
}

/// 包一层：可抹掉 listChildren 的修改时间、固定 findAsset 的修改时间。
class _TimedStore implements SyncAssetStore {
  _TimedStore(this.inner, {required this.listTimes, required this.findTime});

  final SyncAssetStore inner;
  final bool listTimes;
  final int? findTime;

  @override
  Future<String> ensureNamespace(String name) => inner.ensureNamespace(name);

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      inner.ensureFolder(parentId, name);

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      <AssetEntry>[
        for (final AssetEntry e in await inner.listChildren(namespaceId))
          AssetEntry(
            id: e.id,
            name: e.name,
            isFolder: e.isFolder,
            sizeBytes: e.sizeBytes,
            modifiedAt: listTimes ? e.modifiedAt : null,
          ),
      ];

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    final AssetEntry? e = await inner.findAsset(namespaceId, name);
    if (e == null) return null;
    return AssetEntry(id: e.id, name: e.name, modifiedAt: findTime);
  }

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    SyncTransferProgress? onProgress,
  }) => inner.putAsset(namespaceId, name, file, onProgress: onProgress);

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    SyncTransferProgress? onProgress,
  }) => inner.getAsset(assetId, destination, onProgress: onProgress);

  @override
  Future<Object?> getJsonAsset(String assetId) => inner.getJsonAsset(assetId);

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      inner.putJsonAsset(namespaceId, name, json);

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      inner.deleteAsset(id, isFolder: isFolder);
}
