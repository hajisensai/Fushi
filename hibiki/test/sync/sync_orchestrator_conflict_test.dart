import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// Minimal in-memory backend driving the per-book three-way decision in the
/// orchestrator's [SyncManager] sweep. Only the remote progress file (its name
/// encodes the remote timestamp + fraction) and the in-memory `TtuProgress`
/// payload matter; everything the orchestrator's gated-off phases would reach
/// is a loud-throwing stub so an unexpected code path fails the test.
class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend({this.remoteProgressFile, this.remoteProgress});

  DriveFile? remoteProgressFile;
  TtuProgress? remoteProgress;

  /// Captured export write: must stay null in a conflict (nothing pushed).
  TtuProgress? exportedProgress;

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
  Future<DriveSyncFiles> listSyncFiles(String folderId) async =>
      DriveSyncFiles(progress: remoteProgressFile);

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    final TtuProgress? progress = remoteProgress;
    if (progress == null) {
      throw StateError('no remote progress payload seeded');
    }
    return progress;
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    exportedProgress = progress;
  }

  // ── Cache (real persistence path runs harmlessly) ───────────────────
  String? _cachedRoot;
  final Map<String, String> _cachedFolders = <String, String>{};
  @override
  void clearCache() {
    _cachedRoot = null;
    _cachedFolders.clear();
  }

  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {
    _cachedRoot = rootFolderId;
    if (titleToFolderId != null) _cachedFolders.addAll(titleToFolderId);
  }

  @override
  String? get cachedRootFolderId => _cachedRoot;
  @override
  Map<String, String> get cachedFolderIds => _cachedFolders;
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}

  // ── Unreached stub members ──────────────────────────────────────────
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {}
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
  Future<List<DriveFile>> listBooks(String rootFolderId) async => const [];
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async => const [];
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      throw UnimplementedError();
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

  // ── SyncAssetStore (unreached) ──────────────────────────────────────
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
}

/// One 1000-char chapter keeps fraction math simple.
const String _chaptersJson = '[{"characters":1000}]';

DriveFile _progressFile(int timestampMs, double fraction) => DriveFile(
      id: 'progress-id',
      name: progressFileName(timestampMs, fraction),
    );

Future<EpubBookRow> _seedBook(HibikiDatabase db, String title) async {
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/fake/book.epub',
    extractDir: '/fake/extract',
    chapterCount: 1,
    chaptersJson: _chaptersJson,
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ));
  return (await db.getAllEpubBooks()).single;
}

Future<void> _seedPosition(
  HibikiDatabase db,
  String bookKey, {
  required int updatedAt,
  required double fraction,
}) async {
  final int normOffset = (fraction * 10000).round();
  await db.upsertReaderPosition(ReaderPositionsCompanion(
    bookKey: Value(bookKey),
    sectionIndex: const Value(0),
    normCharOffset: Value(normOffset),
    ttuCharOffset: const Value(-1),
    updatedAt: Value(updatedAt),
  ));
}

/// Builds an orchestrator with every phase except the per-book progress sweep
/// gated off, so [SyncOrchestrator.run] only touches `findOrCreateRootFolder`
/// + `syncAllBooks` (the conflict source).
SyncOrchestrator _orchestrator(
  HibikiDatabase db,
  SyncBackend backend,
  Directory work,
) =>
    SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: Directory('${work.path}/dicts')..createSync(),
      audioDatabaseRoot: Directory('${work.path}/audio')..createSync(),
      tempDir: Directory('${work.path}/tmp')..createSync(),
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncAudioBookFiles: false,
      syncDictionary: false,
      syncLocalAudio: false,
    );

void main() {
  const String title = 'Conflict Book';
  final String assetKey = sanitizeTtuFilename(title);

  late Directory work;
  setUp(() async {
    work = await Directory.systemTemp.createTemp('orch_conflict_');
  });
  tearDown(() async {
    if (work.existsSync()) await work.delete(recursive: true);
  });

  test('both sides diverged → conflict collected into report, no import',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);

    final EpubBookRow book = await _seedBook(db, title);
    // Local at ts 120, remote at ts 100, base 50 → both moved off base → fork.
    await _seedPosition(db, book.bookKey, updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(assetKey, 'progress', 50);

    final _FakeSyncBackend backend = _FakeSyncBackend(
      remoteProgressFile: _progressFile(100, 0.4),
      remoteProgress: TtuProgress(
        dataId: 0,
        exploredCharCount: 400,
        progress: 0.4,
        lastBookmarkModified: 100,
      ),
    );

    final SyncRunReport report = await _orchestrator(db, backend, work).run();

    expect(report.conflicts.length, 1);
    final SyncConflict conflict = report.conflicts.single;
    expect(conflict.assetKey, assetKey);
    expect(conflict.dimension, 'progress');
    expect(conflict.title, title);
    expect(conflict.localVersion, 120);
    expect(conflict.remoteVersion, 100);

    // A conflict is neither a transfer nor an error.
    expect(report.booksImported, 0);
    expect(report.errors, isEmpty);

    // Nothing was written: no export, base untouched, local position intact.
    expect(backend.exportedProgress, isNull);
    expect(await db.getSyncBaseline(assetKey, 'progress'), 50);
    final ReaderPositionRow pos = (await db.getReaderPosition(book.bookKey))!;
    expect(pos.updatedAt, 120);

    // Fingerprint embeds both versions so a later edit on either side reopens.
    expect(conflict.fingerprint, '$assetKey|progress|120|100');
  });

  test('non-conflict book (only remote diverged) → no conflict collected',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);

    final EpubBookRow book = await _seedBook(db, title);
    // Local == base 50, only remote moved → clean import, not a fork.
    await _seedPosition(db, book.bookKey, updatedAt: 50, fraction: 0.3);
    await db.setSyncBaseline(assetKey, 'progress', 50);

    final _FakeSyncBackend backend = _FakeSyncBackend(
      remoteProgressFile: _progressFile(100, 0.6),
      remoteProgress: TtuProgress(
        dataId: 0,
        exploredCharCount: 600,
        progress: 0.6,
        lastBookmarkModified: 100,
      ),
    );

    final SyncRunReport report = await _orchestrator(db, backend, work).run();

    expect(report.conflicts, isEmpty);
    expect(report.errors, isEmpty);
  });
}
