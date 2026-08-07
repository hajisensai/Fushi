import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart'
    show isReservedSyncFolderName;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/ttu_models.dart';
import 'package:fushi_core/fushi_core.dart';

// BUG-619 / TODO-1329: an EPUB row with an empty title made every backend's
// `ensureBookFolder('')` resolve `<root>/<''>/` == the sync root, scattering the
// book's progress_/statistics_/audioBook_ JSON (plus cover/epub/.hibikiaudio)
// straight into `hibiki-data/` next to real book folders. These tests pin the
// path contract: an empty sanitized title is never turned into a folder, and the
// per-book sync loop skips such a row entirely (no write ever targets the root).

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// Records the folders `SyncManager` resolves and writes to, so a test can prove
/// no transfer ever targets the sync root. `ensureBookFolder` mirrors the real
/// path-backend derivation `<root>/<sanitized>/` (a normal title yields a real
/// per-book folder; an empty title would collapse onto the root — which the
/// manager must never let happen).
class _RecordingBackend implements SyncBackend {
  static const String root = 'ROOT/';

  final List<String> ensureBookFolderTitles = <String>[];
  final List<String> writeFolderIds = <String>[];

  @override
  Future<String> findOrCreateRootFolder() async => root;

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async {
    ensureBookFolderTitles.add(bookTitle);
    return '$rootFolderId${sanitizeTtuFilename(bookTitle)}/';
  }

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async =>
      const SyncFileTrio(progress: null, statistics: null, audioBook: null);

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async =>
      writeFolderIds.add(folderId);

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async =>
      writeFolderIds.add(folderId);

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async =>
      writeFolderIds.add(folderId);

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async =>
      writeFolderIds.add(folderId);

  // ── Cache (reached by _restore/_persistDriveCache) ──────────────────
  @override
  void clearCache() {}
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  String? get cachedRootFolderId => null;
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};

  // ── Unreached members ───────────────────────────────────────────────
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
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async =>
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
  Future<SyncFileRef?> findContentFile(
          String folderId, String fileName) async =>
      throw UnimplementedError();
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) =>
      throw UnimplementedError();
  @override
  void evictFolderId(String folderId) {}
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
}

Future<EpubBookRow> _insertBook(HibikiDatabase db, String title) async {
  final String bookKey = sanitizeTtuFilename(title);
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: bookKey,
    title: title,
    epubPath: '/fake/book.epub',
    extractDir: '/fake/extract',
    chapterCount: 1,
    chaptersJson: '[]',
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ));
  return (await db.getAllEpubBooks())
      .firstWhere((EpubBookRow b) => b.bookKey == bookKey && b.title == title);
}

void main() {
  group('requireBookFolderName (path contract)', () {
    test('throws on an empty title instead of resolving to the sync root', () {
      expect(() => requireBookFolderName(''), throwsA(isA<SyncBackendError>()));
    });

    test('returns the sanitized folder name for a normal title', () {
      expect(requireBookFolderName('屍人荘の殺人'), '屍人荘の殺人');
      expect(requireBookFolderName('Normal Book'), 'Normal Book');
    });
  });

  group('isReservedSyncFolderName', () {
    test('empty / whitespace names are reserved (never a book folder)', () {
      expect(isReservedSyncFolderName(''), isTrue);
      expect(isReservedSyncFolderName('   '), isTrue);
    });

    test('a real book folder name is not reserved', () {
      expect(isReservedSyncFolderName('屍人荘の殺人'), isFalse);
    });
  });

  group('SyncManager skips empty-title books (no root spill)', () {
    test('empty title: skipped, backend never resolves or writes a folder',
        () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);

      // A degenerate empty-title row that WOULD export (has a reading position
      // and an audiobook position), to prove the skip fires before any write.
      final EpubBookRow book = await _insertBook(db, '');
      await db.upsertReaderPosition(ReaderPositionsCompanion(
        bookKey: Value(book.bookKey),
        sectionIndex: const Value(0),
        normCharOffset: const Value(0),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ));
      await SyncRepository(db).setAudiobookPosition(book.bookKey, 42000);

      final _RecordingBackend backend = _RecordingBackend();
      final SyncManager manager = SyncManager(db: db, backend: backend);

      final SyncBookResult result = await manager.syncBook(
        book: book,
        direction: SyncDirection.exportToTtu,
        syncStats: true,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: true,
      );

      expect(result.direction, SyncResult.skipped);
      expect(backend.ensureBookFolderTitles, isEmpty,
          reason: 'must never resolve a folder for an empty title');
      expect(backend.writeFolderIds, isEmpty,
          reason: 'nothing may be written to the sync root');
    });

    test('normal title: exports into the per-book folder, never the root',
        () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);

      final EpubBookRow book = await _insertBook(db, 'Normal Book');
      await db.upsertReaderPosition(ReaderPositionsCompanion(
        bookKey: Value(book.bookKey),
        sectionIndex: const Value(0),
        normCharOffset: const Value(0),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ));
      await SyncRepository(db).setAudiobookPosition(book.bookKey, 42000);

      final _RecordingBackend backend = _RecordingBackend();
      final SyncManager manager = SyncManager(db: db, backend: backend);

      final SyncBookResult result = await manager.syncBook(
        book: book,
        direction: SyncDirection.exportToTtu,
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: true,
      );

      expect(result.direction, SyncResult.exported);
      expect(backend.ensureBookFolderTitles, contains('Normal Book'));
      expect(backend.writeFolderIds, isNotEmpty);
      const String perBookFolder = '${_RecordingBackend.root}Normal Book/';
      for (final String folderId in backend.writeFolderIds) {
        expect(folderId, perBookFolder);
        expect(folderId, isNot(_RecordingBackend.root));
      }
    });
  });
}
