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
  Future<TtuProgress> getProgressFile(String fileId) async =>
      throw UnimplementedError();
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
  }) async =>
      throw UnimplementedError();
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
    ttuCharOffset: const Value(-1),
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

    test('Sync Audiobook Position defaults on, flips off', () async {
      expect(await repo.isSyncAudioBookEnabled(), isTrue);
      await repo.setSyncAudioBookEnabled(false);
      expect(await repo.isSyncAudioBookEnabled(), isFalse);
    });

    test('Sync book files (content) defaults off, flips on', () async {
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
  });

  group('exportBackup honours the dictionary gate', () {
    test('disabled omits dictionaryResources; enabled includes it', () async {
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

        await SyncRepository(onDiskDb).setSyncDictionaryEnabled(false);
        final String offPath = '${outDir.path}/off.zip';
        await service.exportBackup(offPath);
        final offArchive =
            ZipDecoder().decodeBytes(await File(offPath).readAsBytes());
        expect(offArchive.findFile('dictionaryResources/JMdict/blobs.bin'),
            isNull);

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
          if (d.existsSync()) await d.delete(recursive: true);
        }
      }
    });
  });
}
