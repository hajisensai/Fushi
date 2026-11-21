import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/settings_sync.dart' show kSyncSettingsNamespace;
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart'
    show isReservedSyncFolderName;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:fushi_core/fushi_core.dart';

// BUG-5007：云盘同步根下的 `__settings__`（可移植设置）与 `fushi-srs`（复习同步）是所有设备
// 共用的命名空间，不是书。保留名判据漏了它们时，对比弹窗把它们列成「只剩元数据的远端书」，
// 行菜单里的「删除」会把整个命名空间递归删掉。

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

class _RootFakeBackend implements SyncBackend {
  _RootFakeBackend(this.rootFolders);

  /// 同步根下的一级目录名（id 取同名）。
  final List<String> rootFolders;

  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  String? get cachedRootFolderId => null;
  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {}
  @override
  Future<List<SyncFileRef>> listBooks(
    String rootFolderId,
  ) async => <SyncFileRef>[
    for (final String name in rootFolders) SyncFileRef(id: name, name: name),
  ];
  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}

  @override
  void evictFolderId(String folderId) {}
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  Future<SyncFileTrio> listSyncFiles(String f) async => const SyncFileTrio();
  @override
  Future<List<AssetEntry>> listChildren(String id) async {
    // 命名空间里放的是共享数据（不是 `.epub`）：若被当成书，就是一条「只剩元数据」的远端书。
    return <AssetEntry>[AssetEntry(id: '$id/data', name: 'data.json')];
  }

  // ── Unreached ─────────────────────────────────────────────────────
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
  Future<String> ensureNamespace(String name) async => name;
  @override
  Future<String> ensureFolder(String parentId, String name) async =>
      throw UnimplementedError();
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async => null;
  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<Object?> getJsonAsset(String assetId) async =>
      throw UnimplementedError();
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      throw UnimplementedError();
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async => throw UnimplementedError();
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
  }) async => throw UnimplementedError();
  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async => throw UnimplementedError();
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async => throw UnimplementedError();
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<SyncFileRef?> findContentFile(
    String folderId,
    String fileName,
  ) async => throw UnimplementedError();
  @override
  void clearCache() {}
}

void main() {
  test('设置与复习同步命名空间是保留目录，不是书', () {
    expect(isReservedSyncFolderName(kSyncSettingsNamespace), isTrue);
    expect(isReservedSyncFolderName(kSrsSync2Namespace), isTrue);
    expect(isReservedSyncFolderName('Book A'), isFalse);
  });

  test('云盘对比弹窗不把共享命名空间列成远端书（不给删除入口）', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final List<SyncCompareEntry> entries = await fetchCompareDataForTest(
      db,
      _RootFakeBackend(<String>[
        kSyncSettingsNamespace,
        kSrsSync2Namespace,
        '__pending_mines__',
        'Book A',
      ]),
    );
    expect(entries.map((SyncCompareEntry e) => e.title).toList(), <String>[
      'Book A',
    ]);
  });
}
