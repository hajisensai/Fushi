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

// TODO-703: the compare dialog footer was reworded for clarity --
//   * the plain dismiss button now reads t.sync_compare_close (a dedicated
//     key), no longer the shared t.dialog_done;
//   * the primary action keeps key sync_compare_apply but its value reads
//     Sync now (N).
// These widget tests pin both the labels AND the behavior: Close must only
// pop (never run a sync); Sync-now must run _applyChoices (an export here).

HibikiDatabase _memDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _chaptersJson = '[{"characters":1000}]';

// Minimal backend double exercising the dialog _load (conflict surface) and
// Apply (updateProgressFile) paths. Other members throw to fail loudly if an
// unexpected route is taken.
class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend({required this.remoteBooks});

  final Map<String, _RemoteBook> remoteBooks;

  // Captured export writes keyed by folder id. Empty means no sync ran.
  final Map<String, TtuProgress> exportedByFolder = <String, TtuProgress>{};

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
  void evictFolderId(String folderId) {}
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

  // Unreached members.
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

class _RemoteBook {
  _RemoteBook({required this.folderId, this.progressFile, this.payload});

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
    updatedAt: Value(updatedAt),
  ));
}

// Seeds one book whose local and remote both diverged from base (a conflict),
// so the dialog renders entries and the primary action button is present.
Future<_FakeSyncBackend> _seedConflict(HibikiDatabase db) async {
  final EpubBookRow book = await _seedBook(db, 'BookA');
  await _seedPosition(db, book.bookKey, updatedAt: 120, fraction: 0.6);
  await db.setSyncBaseline(sanitizeTtuFilename('BookA'), 'progress', 50);
  return _FakeSyncBackend(
    remoteBooks: <String, _RemoteBook>{
      'BookA': _RemoteBook.withProgress(
        folderId: 'folderA',
        timestampMs: 100,
        fraction: 0.4,
      ),
    },
  );
}

Future<void> _pumpDialog(
  WidgetTester tester,
  HibikiDatabase db,
  _FakeSyncBackend fake,
) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => SyncCompareDialog(db: db, backend: fake),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets(
      'footer uses sync_compare_close (not shared dialog_done) and tapping it '
      'only pops, no sync runs', (WidgetTester tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final _FakeSyncBackend fake = await _seedConflict(db);

    await _pumpDialog(tester, db, fake);

    // Dialog is up with a conflict entry.
    expect(find.text(t.sync_compare_conflicts), findsOneWidget);
    // The dismiss button reads the new dedicated close key, not dialog_done.
    expect(find.text(t.sync_compare_close), findsOneWidget);
    expect(find.text(t.dialog_done), findsNothing);

    // Tapping Close pops the dialog and runs NO sync (no export captured).
    await tester.tap(find.text(t.sync_compare_close));
    await tester.pumpAndSettle();
    expect(find.text(t.sync_compare_conflicts), findsNothing,
        reason: 'Close must pop the compare dialog');
    expect(fake.exportedByFolder, isEmpty,
        reason: 'Close is a pure dismiss, it must not trigger a sync');
  });

  testWidgets(
      'primary action reads sync_compare_apply(count) and tapping it runs '
      '_applyChoices (an export)', (WidgetTester tester) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final _FakeSyncBackend fake = await _seedConflict(db);

    await _pumpDialog(tester, db, fake);

    // Resolve the conflict (use local, export direction) so Apply is enabled
    // and its count reflects the single actionable entry.
    await tester.tap(find.text(t.sync_compare_use_local).first);
    await tester.pumpAndSettle();

    // The primary button carries the sync_compare_apply key (value Sync now).
    expect(find.text(t.sync_compare_apply(count: 1)), findsOneWidget);

    await tester.tap(find.text(t.sync_compare_apply(count: 1)));
    await tester.pumpAndSettle();

    // _applyChoices truly ran: the conflict folder progress was exported.
    expect(fake.exportedByFolder.keys, contains('folderA'),
        reason: 'Sync now must trigger _applyChoices (the manual export)');
  });
}
