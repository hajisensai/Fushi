import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// One chapter of 1000 characters keeps fraction math simple: explored chars
/// map linearly to normCharOffset in 0..10000.
const String _chaptersJson = '[{"characters":1000}]';

/// Backend test double for the compare dialog's baseline-conflict surface.
///
/// Each remote book folder gets a [_RemoteBook] entry carrying its progress
/// file metadata (name encodes timestamp+fraction) and payload. The dialog's
/// `_load` reads `listBooks` → per-folder `listSyncFiles` → `getProgressFile`;
/// Apply's manual export reaches `updateProgressFile`. Members not on those
/// paths throw so an unexpected route fails loudly.
class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend({required this.remoteBooks});

  /// title → remote book data (folder id + progress file/payload).
  final Map<String, _RemoteBook> remoteBooks;

  /// Captured export writes keyed by folder id, for base-write assertions.
  final Map<String, TtuProgress> exportedByFolder = <String, TtuProgress>{};

  // ── Read methods the dialog's _load path needs ────────────────────
  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async => <DriveFile>[
        for (final MapEntry<String, _RemoteBook> e in remoteBooks.entries)
          DriveFile(id: e.value.folderId, name: e.key),
      ];
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}
  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async {
    final _RemoteBook? book = _byFolder(folderId);
    if (book == null) return const DriveSyncFiles();
    return DriveSyncFiles(progress: book.progressFile);
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    for (final _RemoteBook b in remoteBooks.values) {
      if (b.progressFile?.id == fileId) return b.payload!;
    }
    throw StateError('no remote progress payload for $fileId');
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    exportedByFolder[folderId] = progress;
  }

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async =>
      remoteBooks[bookTitle]?.folderId ?? 'folder-$bookTitle';

  @override
  Future<String> ensureNamespace(String name) async => name;
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      const <AssetEntry>[];

  _RemoteBook? _byFolder(String folderId) {
    for (final _RemoteBook b in remoteBooks.values) {
      if (b.folderId == folderId) return b;
    }
    return null;
  }

  // ── Cache (real persistence path runs harmlessly) ─────────────────
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
  Future<bool> get isAuthenticated async => true;

  // ── Unreached members ─────────────────────────────────────────────
  @override
  Future<String?> get currentEmail async => throw UnimplementedError();
  @override
  Future<void> authenticate({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<void> signOut({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<bool> restoreAuth(SyncRepository repo) async =>
      throw UnimplementedError();
  @override
  Future<void> refreshAuth() async => throw UnimplementedError();
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
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
  Future<void> deleteAsset(String id, {bool isFolder = false}) async =>
      throw UnimplementedError();
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureFolder(String parentId, String name) async =>
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
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      throw UnimplementedError();
}

/// Remote book fixture: a folder + an optional progress file (name encodes
/// timestamp/fraction) and the payload `getProgressFile` returns.
class _RemoteBook {
  _RemoteBook({
    required this.folderId,
    this.progressFile,
    this.payload,
  });

  final String folderId;
  final DriveFile? progressFile;
  final TtuProgress? payload;

  factory _RemoteBook.withProgress({
    required String folderId,
    required int timestampMs,
    required double fraction,
  }) {
    final int exploredChars = (fraction * 1000).round();
    return _RemoteBook(
      folderId: folderId,
      progressFile: DriveFile(
        id: 'progress-$folderId',
        name: progressFileName(timestampMs, fraction),
      ),
      payload: TtuProgress(
        dataId: 0,
        exploredCharCount: exploredChars,
        progress: fraction,
        lastBookmarkModified: timestampMs,
      ),
    );
  }
}

Future<EpubBookRow> _seedBook(HibikiDatabase db, String title) async {
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/fake/$title.epub',
    extractDir: '/fake/$title',
    chapterCount: 1,
    chaptersJson: _chaptersJson,
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ));
  return (await db.getAllEpubBooks()).firstWhere((b) => b.title == title);
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

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  /// Pumps the compare dialog over a caller-supplied [db] (so the test can seed
  /// books/positions/baselines first), waits for `_load` to settle.
  Future<void> pumpDialog(
    WidgetTester tester,
    HibikiDatabase db,
    _FakeSyncBackend fake, {
    bool conflictsOnly = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SyncCompareDialog(
              db: db,
              backend: fake,
              conflictsOnly: conflictsOnly,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('single-sided change is not a conflict (local == base)',
      (WidgetTester tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    final EpubBookRow book = await _seedBook(db, 'BookA');
    // Local sat still at base 100; remote moved to 120 → only remote diverged.
    await _seedPosition(db, book.bookKey, updatedAt: 100, fraction: 0.5);
    await db.setSyncBaseline(sanitizeTtuFilename('BookA'), 'progress', 100);

    final _FakeSyncBackend fake = _FakeSyncBackend(
      remoteBooks: <String, _RemoteBook>{
        'BookA': _RemoteBook.withProgress(
          folderId: 'folderA',
          timestampMs: 120,
          fraction: 0.6,
        ),
      },
    );
    await pumpDialog(tester, db, fake);

    expect(find.text('BookA'), findsOneWidget);
    // No conflict header — single-sided change resolves automatically.
    expect(find.text(t.sync_compare_conflicts), findsNothing);
  });

  testWidgets('both sides diverged from base is a conflict',
      (WidgetTester tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    final EpubBookRow book = await _seedBook(db, 'BookA');
    await _seedPosition(db, book.bookKey, updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(sanitizeTtuFilename('BookA'), 'progress', 50);

    final _FakeSyncBackend fake = _FakeSyncBackend(
      remoteBooks: <String, _RemoteBook>{
        'BookA': _RemoteBook.withProgress(
          folderId: 'folderA',
          timestampMs: 100,
          fraction: 0.4,
        ),
      },
    );
    await pumpDialog(tester, db, fake);

    // Conflict section is rendered; the choice segmented button is present.
    expect(find.text(t.sync_compare_conflicts), findsOneWidget);
    expect(find.text('BookA'), findsOneWidget);
  });

  testWidgets('conflictsOnly hides non-conflict books and dictionaries',
      (WidgetTester tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    // Conflict book: both sides off base.
    final EpubBookRow conflictBook = await _seedBook(db, 'ConflictBook');
    await _seedPosition(db, conflictBook.bookKey,
        updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(
        sanitizeTtuFilename('ConflictBook'), 'progress', 50);

    // Calm book: single-sided (local == base), resolves automatically.
    final EpubBookRow calmBook = await _seedBook(db, 'CalmBook');
    await _seedPosition(db, calmBook.bookKey, updatedAt: 100, fraction: 0.5);
    await db.setSyncBaseline(sanitizeTtuFilename('CalmBook'), 'progress', 100);

    final _FakeSyncBackend fake = _FakeSyncBackend(
      remoteBooks: <String, _RemoteBook>{
        'ConflictBook': _RemoteBook.withProgress(
          folderId: 'folderC',
          timestampMs: 100,
          fraction: 0.4,
        ),
        'CalmBook': _RemoteBook.withProgress(
          folderId: 'folderK',
          timestampMs: 120,
          fraction: 0.6,
        ),
      },
    );
    await pumpDialog(tester, db, fake, conflictsOnly: true);

    expect(find.text('ConflictBook'), findsOneWidget);
    expect(find.text('CalmBook'), findsNothing);
  });

  testWidgets(
      'conflictsOnly Apply only syncs conflict books, not hidden non-conflict ones',
      (WidgetTester tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    // Conflict book: both sides off base → manual choice required.
    final EpubBookRow conflictBook = await _seedBook(db, 'ConflictBook');
    await _seedPosition(db, conflictBook.bookKey,
        updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(
        sanitizeTtuFilename('ConflictBook'), 'progress', 50);

    // Calm book: single-sided local change (remote == base) → auto-export
    // direction, seeded as useLocal. It is HIDDEN in conflictsOnly mode, so
    // Apply must NOT touch its remote folder. This is the [Important] guard.
    final EpubBookRow calmBook = await _seedBook(db, 'CalmBook');
    await _seedPosition(db, calmBook.bookKey, updatedAt: 200, fraction: 0.7);
    await db.setSyncBaseline(sanitizeTtuFilename('CalmBook'), 'progress', 100);

    final _FakeSyncBackend fake = _FakeSyncBackend(
      remoteBooks: <String, _RemoteBook>{
        'ConflictBook': _RemoteBook.withProgress(
          folderId: 'folderC',
          timestampMs: 100,
          fraction: 0.4,
        ),
        'CalmBook': _RemoteBook.withProgress(
          folderId: 'folderK',
          timestampMs: 100, // remote == base → single-sided, not a conflict.
          fraction: 0.5,
        ),
      },
    );
    await pumpDialog(tester, db, fake, conflictsOnly: true);

    // Only the conflict book is visible; Apply count reflects the single
    // conflict, not the hidden calm book.
    expect(find.text('ConflictBook'), findsOneWidget);
    expect(find.text('CalmBook'), findsNothing);

    // Resolve the conflict to export (use local), then Apply.
    await tester.tap(find.text(t.sync_compare_use_local).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.sync_compare_apply(count: 1)));
    await tester.pumpAndSettle();

    // Fake backend recorded an export ONLY for the conflict folder; the hidden
    // calm book's folder was never synced.
    expect(fake.exportedByFolder.keys, contains('folderC'));
    expect(fake.exportedByFolder.keys, isNot(contains('folderK')));
  });

  testWidgets('conflictsOnly with zero conflicts shows the empty state',
      (WidgetTester tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    // A library with one non-conflict (single-sided) book and no conflicts.
    final EpubBookRow calmBook = await _seedBook(db, 'CalmBook');
    await _seedPosition(db, calmBook.bookKey, updatedAt: 200, fraction: 0.7);
    await db.setSyncBaseline(sanitizeTtuFilename('CalmBook'), 'progress', 100);

    final _FakeSyncBackend fake = _FakeSyncBackend(
      remoteBooks: <String, _RemoteBook>{
        'CalmBook': _RemoteBook.withProgress(
          folderId: 'folderK',
          timestampMs: 100, // remote == base → single-sided, not a conflict.
          fraction: 0.5,
        ),
      },
    );
    await pumpDialog(tester, db, fake, conflictsOnly: true);

    // No phantom blank list: an explicit empty-state message is shown.
    expect(find.text(t.sync_compare_empty), findsOneWidget);
    expect(find.text('CalmBook'), findsNothing);
  });

  testWidgets('resolving a conflict via Apply writes the baseline',
      (WidgetTester tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    final EpubBookRow book = await _seedBook(db, 'BookA');
    await _seedPosition(db, book.bookKey, updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(sanitizeTtuFilename('BookA'), 'progress', 50);

    final _FakeSyncBackend fake = _FakeSyncBackend(
      remoteBooks: <String, _RemoteBook>{
        'BookA': _RemoteBook.withProgress(
          folderId: 'folderA',
          timestampMs: 100,
          fraction: 0.4,
        ),
      },
    );
    await pumpDialog(tester, db, fake);

    expect(find.text(t.sync_compare_conflicts), findsOneWidget);

    // Pick "use local" (export) for the conflict, then Apply.
    await tester.tap(find.text(t.sync_compare_use_local).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.sync_compare_apply(count: 1)));
    await tester.pumpAndSettle();

    // Manual export ran (folder progress written) and the baseline advanced to
    // the local version — so the divergence no longer reads as a conflict.
    expect(fake.exportedByFolder['folderA']?.lastBookmarkModified, 120);
    expect(await db.getSyncBaseline(sanitizeTtuFilename('BookA'), 'progress'),
        120);
  });
}
