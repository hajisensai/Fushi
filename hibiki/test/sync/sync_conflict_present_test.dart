import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_conflict_prompter.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// One chapter of 1000 characters keeps fraction math simple.
const String _chaptersJson = '[{"characters":1000}]';

/// Backend test double for the conflict-resolution surface presented by
/// [SyncConflictPrompter.present] → [SyncCompareDialog] (conflictsOnly). Same
/// shape as the compare-dialog test's fake: the `_load` path reads listBooks →
/// listSyncFiles → getProgressFile; members off that path throw.
class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend({required this.remoteBooks});

  final Map<String, _RemoteBook> remoteBooks;
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

/// One genuine fork (both sides off baseline) → SyncCompareDialog renders it as
/// a conflict.
List<SyncConflict> _oneConflict() => <SyncConflict>[
      SyncConflict(
        assetKey: sanitizeTtuFilename('BookA'),
        dimension: 'progress',
        title: 'BookA',
        localVersion: 120,
        remoteVersion: 100,
      ),
    ];

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  /// Seeds a forked BookA (both sides off baseline 50) so the conflictsOnly
  /// dialog has a real conflict row to render.
  Future<(HibikiDatabase, _FakeSyncBackend)> seedForkedLibrary() async {
    final HibikiDatabase db = _memDb();
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
    return (db, fake);
  }

  /// Pumps a real app with an attached navigatorKey, then fires
  /// `prompter.present(...)` over that key and settles. The MaterialApp must be
  /// pumped (navigator attached) before present runs so
  /// `navigatorKey.currentContext` is non-null.
  ///
  /// [body] is started but NOT awaited to completion: when present DOES show the
  /// conflict dialog, its future only resolves once the (barrier-undismissible)
  /// dialog is popped, so awaiting it here would deadlock pumpAndSettle. The
  /// caller pops the dialog after asserting (see showing tests). When present
  /// suppresses the dialog, its future completes immediately and there is
  /// nothing left pending.
  Future<void> pumpAndPresent(
    WidgetTester tester, {
    required SyncConflictPrompter prompter,
    required GlobalKey<NavigatorState> navKey,
    required Future<void> Function() body,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    unawaited(body());
    await tester.pumpAndSettle();
  }

  /// Pops the open conflict dialog with a null result (user cancelled) and
  /// settles, letting the pending `present` future resolve so no work is left
  /// dangling after the test body returns.
  Future<void> dismissDialog(
    WidgetTester tester,
    GlobalKey<NavigatorState> navKey,
  ) async {
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
  }

  testWidgets('manual source presents the conflict resolution dialog',
      (WidgetTester tester) async {
    final (HibikiDatabase db, _FakeSyncBackend fake) =
        await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.manual,
        inBook: true, // manual ignores in-book.
      ),
    );

    expect(find.byType(SyncCompareDialog), findsOneWidget);
    expect(find.text(t.sync_compare_conflicts), findsOneWidget);
    expect(find.text('BookA'), findsOneWidget);

    await dismissDialog(tester, navKey);
  });

  testWidgets('auto source while in-book does NOT present',
      (WidgetTester tester) async {
    final (HibikiDatabase db, _FakeSyncBackend fake) =
        await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.auto,
        inBook: true, // auto + in-book is suppressed.
      ),
    );

    expect(find.byType(SyncCompareDialog), findsNothing);
  });

  testWidgets('background source never presents', (WidgetTester tester) async {
    final (HibikiDatabase db, _FakeSyncBackend fake) =
        await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.background,
        inBook: false,
      ),
    );

    expect(find.byType(SyncCompareDialog), findsNothing);
  });

  testWidgets('auto source out-of-book presents the dialog',
      (WidgetTester tester) async {
    final (HibikiDatabase db, _FakeSyncBackend fake) =
        await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.auto,
        inBook: false, // out of book → auto can prompt.
      ),
    );

    expect(find.byType(SyncCompareDialog), findsOneWidget);
    expect(find.text('BookA'), findsOneWidget);

    await dismissDialog(tester, navKey);
  });
}
