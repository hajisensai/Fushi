import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'temp_dir_cleanup.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// Recording fake [SyncBackend]: drives `syncBook` through a successful EXPORT
/// so we can observe which sync channels each gate opens. Unrelated members
/// throw so an accidental code-path change fails loudly.
class _RecordingExportBackend implements SyncBackend {
  _RecordingExportBackend({this.remoteFiles = const DriveSyncFiles()});

  final DriveSyncFiles remoteFiles;

  int updateStatsCalls = 0;
  int updateProgressCalls = 0;
  int updateAudioBookCalls = 0;
  int downloadContentCalls = 0;
  String? lastStatsFileId;
  String? lastAudioBookFileId;

  @override
  Future<String> findOrCreateRootFolder() async => 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async =>
      'folder';

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async => remoteFiles;

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    updateProgressCalls++;
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    updateStatsCalls++;
    lastStatsFileId = fileId;
  }

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async => const [];

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    updateAudioBookCalls++;
    lastAudioBookFileId = fileId;
  }

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

  // ── SyncAssetStore (unused by this test) ──────────────────────────
  @override
  Future<String> ensureNamespace(String name) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureFolder(String parentId, String name) async =>
      throw UnimplementedError();
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      throw UnimplementedError();
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async =>
      throw UnimplementedError();
  @override
  Future<void> putAsset(String namespaceId, String name, File file,
          {void Function(double progress)? onProgress}) async =>
      throw UnimplementedError();
  @override
  Future<void> getAsset(String assetId, File destination,
          {void Function(double progress)? onProgress}) async =>
      throw UnimplementedError();
  @override
  Future<Object?> getJsonAsset(String assetId) async =>
      throw UnimplementedError();
  @override
  Future<void> putJsonAsset(
          String namespaceId, String name, Object? json) async =>
      throw UnimplementedError();
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async =>
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
  Future<List<DriveFile>> listBooks(String rootFolderId) async =>
      throw UnimplementedError();
  @override
  Future<TtuProgress> getProgressFile(String fileId) async => TtuProgress(
        dataId: 0,
        exploredCharCount: 80,
        progress: 0.8,
        lastBookmarkModified: 2000,
      );
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
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
  }) async {
    downloadContentCalls++;
  }

  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async =>
      throw UnimplementedError();
}

Future<EpubBookRow> _seedBookWithPosition(HibikiDatabase db) async {
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: 'Book',
    title: 'Book',
    epubPath: '/fake/book.epub',
    extractDir: '/fake/extract',
    chapterCount: 1,
    chaptersJson: '[{"characters":100}]',
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ));
  final EpubBookRow book = (await db.getAllEpubBooks()).single;
  await db.upsertReaderPosition(ReaderPositionsCompanion(
    bookKey: Value(book.bookKey),
    sectionIndex: const Value(0),
    normCharOffset: const Value(5000),
    updatedAt: const Value(1000),
  ));
  await db.setReadingStatistic(ReadingStatisticsCompanion.insert(
    title: 'Book',
    dateKey: '2026-06-03',
    charactersRead: 50,
    readingTimeMs: 60000,
    lastStatisticModified: 1000,
  ));
  return book;
}

void main() {
  group('SyncRepository gating toggles (defaults + flip)', () {
    late HibikiDatabase db;
    late SyncRepository repo;

    setUp(() {
      db = _memDb();
      repo = SyncRepository(db);
    });
    tearDown(() => db.close());

    test('Auto Sync defaults off, flips on', () async {
      expect(await repo.isAutoSyncEnabled(), isFalse);
      await repo.setAutoSyncEnabled(true);
      expect(await repo.isAutoSyncEnabled(), isTrue);
    });

    test('Sync Statistics defaults on, flips off', () async {
      expect(await repo.isSyncStatsEnabled(), isTrue);
      await repo.setSyncStatsEnabled(false);
      expect(await repo.isSyncStatsEnabled(), isFalse);
    });

    test('audiobook position sync is always enabled', () async {
      expect(await repo.isSyncAudioBookEnabled(), isTrue);
      await repo.setSyncAudioBookEnabled(false);
      expect(await repo.isSyncAudioBookEnabled(), isTrue);
    });

    test('Upload book files (content) defaults off, flips on', () async {
      expect(await repo.isSyncContentEnabled(), isFalse);
      await repo.setSyncContentEnabled(true);
      expect(await repo.isSyncContentEnabled(), isTrue);
    });

    test('Sync dictionaries defaults off, flips on', () async {
      expect(await repo.isSyncDictionaryEnabled(), isFalse);
      await repo.setSyncDictionaryEnabled(true);
      expect(await repo.isSyncDictionaryEnabled(), isTrue);
    });
  });

  group('syncBook honours the statistics gate', () {
    test('syncStats:false skips updateStatsFile', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final EpubBookRow book = await _seedBookWithPosition(db);

      final backend = _RecordingExportBackend(
        remoteFiles: const DriveSyncFiles(
          statistics: DriveFile(id: 'remote-stats', name: 'statistics.json'),
        ),
      );
      final manager = SyncManager(db: db, backend: backend);

      final SyncBookResult result = await manager.syncBook(
        book: book,
        direction: SyncDirection.exportToTtu,
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
      );

      expect(result.direction, SyncResult.exported);
      expect(backend.updateProgressCalls, 1);
      expect(backend.updateStatsCalls, 0);
    });

    test('syncStats:true exports statistics using the discovered file id',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final EpubBookRow book = await _seedBookWithPosition(db);

      final backend = _RecordingExportBackend(
        remoteFiles: const DriveSyncFiles(
          statistics: DriveFile(id: 'remote-stats', name: 'statistics.json'),
        ),
      );
      final manager = SyncManager(db: db, backend: backend);

      final SyncBookResult result = await manager.syncBook(
        book: book,
        direction: SyncDirection.exportToTtu,
        syncStats: true,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
      );

      expect(result.direction, SyncResult.exported);
      expect(backend.updateProgressCalls, 1);
      expect(backend.updateStatsCalls, 1);
      expect(backend.lastStatsFileId, 'remote-stats');
    });

    test('syncContent:true imports remote metadata without downloading files',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final EpubBookRow book = await _seedBookWithPosition(db);

      final backend = _RecordingExportBackend(
        remoteFiles: const DriveSyncFiles(
          progress: DriveFile(
            id: 'remote-progress',
            name: 'progress_1_6_2000_0.8.json',
          ),
        ),
      );
      final manager = SyncManager(db: db, backend: backend);

      final SyncBookResult result = await manager.syncBook(
        book: book,
        direction: SyncDirection.importFromTtu,
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
        syncContent: true,
      );

      expect(result.direction, SyncResult.imported);
      expect(backend.downloadContentCalls, 0,
          reason: 'Upload book files 不能在导入远端元数据时顺手下载内容文件');
      final ReaderPositionRow? pos = await db.getReaderPosition(book.bookKey);
      expect(pos?.updatedAt, 2000, reason: '进度/冲突解决仍应接受远端元数据');
    });
  });

  group('progress tie-break compares at storage resolution (BUG-162)', () {
    test('imported-then-unmoved re-sync is synced, not a spurious re-export',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      // 本地 (section 0, norm 5000)，chaptersJson characters=100 →
      // explored 50 / 100 = 0.5（落在 normCharOffset 存储网格上）；updatedAt=1000。
      final EpubBookRow book = await _seedBookWithPosition(db);

      // 远端进度文件：同时间戳(1000)，原始分数 0.5005 —— 比本地能存的网格更细，但
      // 量化到同一网格格（round(0.5005*100)=50 → norm 5000 → 0.5）。修前按裸 1e-6 比会
      // 误判「位置不同」→ 走 import/export 重传（spurious），把云端原值改写成近似；修后
      // 先把远端分数投影到存储网格再比 → 相等 → synced，云端原值原样保留。
      final backend = _RecordingExportBackend(
        remoteFiles: const DriveSyncFiles(
          progress: DriveFile(
              id: 'remote-progress', name: 'progress_1_6_1000_0.5005.json'),
        ),
      );
      final manager = SyncManager(db: db, backend: backend);

      // 自动方向（direction 省略）→ 时间戳撞 tie → 内容 tie-break。
      final SyncBookResult result = await manager.syncBook(
        book: book,
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
      );

      expect(result.direction, SyncResult.synced);
      expect(backend.updateProgressCalls, 0,
          reason: '未移动不得重导出（否则云端 exploredCharCount 被二次换算改写）');
    });
  });

  group('exportBackup includes dictionary resources whenever present', () {
    // Full-data backup packs everything that exists on disk: the dictionary
    // resources are no longer gated on the sync-dictionary toggle. (Absence of
    // the resource files still strips the dictionary DB rows — covered in
    // backup_service_test.dart.)
    test('included regardless of the sync-dictionary toggle', () async {
      final Directory dbDir =
          await Directory.systemTemp.createTemp('t4_dict_db_');
      final Directory dictDir =
          await Directory.systemTemp.createTemp('t4_dict_res_');
      final Directory outDir =
          await Directory.systemTemp.createTemp('t4_dict_out_');
      final HibikiDatabase onDiskDb = HibikiDatabase(dbDir.path);
      try {
        await Directory('${dictDir.path}/JMdict').create(recursive: true);
        await File('${dictDir.path}/JMdict/blobs.bin')
            .writeAsString('dictionary index');
        await onDiskDb.upsertDictionaryMeta(
          DictionaryMetadataCompanion.insert(
            name: 'JMdict',
            formatKey: 'yomichan',
            order: 0,
          ),
        );

        final service = BackupService(
          db: onDiskDb,
          dbDirectory: dbDir.path,
          dictionaryResourceDirectory: dictDir.path,
          appVersion: '1.0.0',
        );

        // Toggle OFF: full-data backup still includes the resources (the
        // sync-dictionary gate no longer applies to local backup).
        await SyncRepository(onDiskDb).setSyncDictionaryEnabled(false);
        final String offPath = '${outDir.path}/off.zip';
        await service.exportBackup(offPath);
        final offArchive =
            ZipDecoder().decodeBytes(await File(offPath).readAsBytes());
        expect(offArchive.findFile('dictionaryResources/JMdict/blobs.bin'),
            isNotNull);

        // Toggle ON: also included.
        await SyncRepository(onDiskDb).setSyncDictionaryEnabled(true);
        final String onPath = '${outDir.path}/on.zip';
        await service.exportBackup(onPath);
        final onArchive =
            ZipDecoder().decodeBytes(await File(onPath).readAsBytes());
        expect(onArchive.findFile('dictionaryResources/JMdict/blobs.bin'),
            isNotNull);
      } finally {
        await onDiskDb.close();
        for (final Directory d in [dbDir, dictDir, outDir]) {
          if (d.existsSync()) await cleanupTempDir(d);
        }
      }
    });
  });
}
