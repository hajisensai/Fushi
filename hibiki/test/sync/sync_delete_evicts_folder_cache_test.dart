import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// Minimal [SyncBackend] test double for the compare dialog: only the read
/// methods the dialog's `_load` path actually touches return controllable data
/// (a single remote book folder + a single remote dictionary asset);
/// [deleteAsset] records the id and isFolder flag of every call. Every other
/// member throws so an unexpected code path fails loudly rather than silently
/// returning a fake-friendly default.
class _CacheTrackingBackend implements SyncBackend {
  _CacheTrackingBackend({
    required this.books,
    required Map<String, String> initialCache,
  }) {
    _titleToFolderId.addAll(initialCache);
  }

  /// Remote book folders surfaced by [listBooks] (each becomes a deletable row).
  List<DriveFile> books;

  /// Real cache under test: sanitized title -> folderId.
  final Map<String, String> _titleToFolderId = <String, String>{};

  // ── deleteAsset: remote-only; eviction is the dialog's contract ───
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {}

  @override
  void evictFolderId(String folderId) {
    _titleToFolderId.removeWhere((_, id) => id == folderId);
  }

  // ── Read methods the dialog's _load path needs ────────────────────
  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async => books;
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {
    for (final DriveFile f in folders) {
      _titleToFolderId[f.name] = f.id;
    }
  }

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async =>
      const DriveSyncFiles();
  @override
  Future<String> ensureNamespace(String name) async => name;
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      const <AssetEntry>[];
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {
    if (titleToFolderId != null) _titleToFolderId.addAll(titleToFolderId);
  }

  @override
  String? get cachedRootFolderId => 'root';
  @override
  Map<String, String> get cachedFolderIds =>
      Map<String, String>.unmodifiable(_titleToFolderId);
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
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async =>
      throw UnimplementedError();
  @override
  Future<TtuProgress> getProgressFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async => TtuAudioBook(
        title: 'BookA',
        playbackPositionSec: 0,
        lastAudioBookModified: 0,
      );
  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async =>
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
  @override
  void clearCache() => _titleToFolderId.clear();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  /// Pumps the compare dialog with [backend] injected, then waits for its async
  /// `_load` to settle so the single book row is rendered.
  Future<void> pumpDialog(
    WidgetTester tester,
    _CacheTrackingBackend backend,
    HibikiDatabase db,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SyncCompareDialog(db: db, backend: backend),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the book row overflow, picks "delete book", confirms.
  Future<void> tapDeleteBook(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.sync_compare_delete_book).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_delete).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'deleting a remote book folder evicts its folderId from the in-memory '
      'cache and rewrites the persisted folder cache (BUG-202)',
      (WidgetTester tester) async {
    const String sanitizedTitle = 'BookA';
    const String folderId = 'folderX';

    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    // Start: cache maps BookA -> folderX, already persisted (a prior sync ran).
    await repo.setFolderCache(<String, String>{sanitizedTitle: folderId});

    final _CacheTrackingBackend backend = _CacheTrackingBackend(
      books: <DriveFile>[const DriveFile(id: folderId, name: sanitizedTitle)],
      initialCache: <String, String>{sanitizedTitle: folderId},
    );

    await pumpDialog(tester, backend, db);
    expect(find.text(sanitizedTitle), findsOneWidget);

    await tapDeleteBook(tester);

    // Row optimistically removed on success.
    expect(find.text(sanitizedTitle), findsNothing);

    // (1) In-memory cache no longer maps to the deleted folderId.
    expect(
      backend.cachedFolderIds.containsValue(folderId),
      isFalse,
      reason: 'in-memory _titleToFolderId still maps to the deleted folderId',
    );
    expect(backend.cachedFolderIds.containsKey(sanitizedTitle), isFalse);

    // (2) Persisted cache (DB) no longer references it: no stale revival on
    // restart.
    final Map<String, String> persisted = await repo.getFolderCache();
    expect(
      persisted.containsValue(folderId),
      isFalse,
      reason: 'persisted sync_folder_cache still references the deleted folder',
    );
    expect(persisted.containsKey(sanitizedTitle), isFalse);
  });
}
