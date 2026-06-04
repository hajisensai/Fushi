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
class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend({required this.books, required this.dictAssets});

  /// Remote book folders surfaced by [listBooks] (each becomes a deletable row).
  List<DriveFile> books;

  /// Remote dictionary assets surfaced under the `__dictionaries__` namespace.
  List<AssetEntry> dictAssets;

  /// Ordered ids passed to [deleteAsset].
  final List<String> deletedIds = <String>[];

  /// id -> isFolder flag recorded per [deleteAsset] call.
  final Map<String, bool> deletedFolderFlags = <String, bool>{};

  /// When true, [deleteAsset] throws to exercise the failure path.
  bool failDelete = false;

  /// When true, [listSyncFiles] reports a remote audiobook asset (id
  /// [audioAssetId]) for every book folder, so the row exposes a "delete remote
  /// audiobook" action. Default false keeps the other cases' empty contract.
  bool withAudio = false;

  /// Native locator of the synthesised remote audiobook asset.
  static const String audioAssetId = 'audioAsset1';

  static const String _dictNs = '__dictionaries__';

  // ── deleteAsset (the unit under test) ─────────────────────────────
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    deletedIds.add(id);
    deletedFolderFlags[id] = isFolder;
    if (failDelete) {
      throw SyncBackendError('boom');
    }
  }

  // ── Read methods the dialog's _load path needs ────────────────────
  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async => books;
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}
  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async => withAudio
      // Only the audioBook field is populated, so _fetchRemoteBookData touches
      // getAudioBookFile but never getProgressFile/getStatsFile.
      ? const DriveSyncFiles(
          audioBook: DriveFile(id: audioAssetId, name: 'audiobook.hibikiaudio'),
        )
      : const DriveSyncFiles();
  @override
  Future<String> ensureNamespace(String name) async => name;
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async =>
      namespaceId == _dictNs ? dictAssets : const <AssetEntry>[];
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  String? get cachedRootFolderId => null;
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
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
  // Reached only when [withAudio] is on (listSyncFiles surfaces an audioBook);
  // _fetchRemoteBookData reads playbackPositionSec off the returned instance.
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
  void clearCache() => throw UnimplementedError();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  /// Pumps the compare dialog with [fake] injected, then waits for its async
  /// `_load` to settle so the book/dictionary rows are rendered.
  Future<HibikiDatabase> pumpDialog(
    WidgetTester tester,
    _FakeSyncBackend fake,
  ) async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SyncCompareDialog(db: db, backend: fake),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return db;
  }

  /// Opens the row's delete overflow menu, picks the item labelled [menuLabel],
  /// then confirms the deletion in the confirm dialog.
  Future<void> tapDeleteAndConfirm(
    WidgetTester tester, {
    required Finder rowDeleteIcon,
    required String menuLabel,
  }) async {
    await tester.tap(rowDeleteIcon);
    await tester.pumpAndSettle();
    await tester.tap(find.text(menuLabel).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_delete).last);
    await tester.pumpAndSettle();
  }

  testWidgets('book row delete calls deleteAsset on remote folder id (folder)',
      (WidgetTester tester) async {
    final _FakeSyncBackend fake = _FakeSyncBackend(
      books: <DriveFile>[const DriveFile(id: 'folderX', name: 'BookA')],
      dictAssets: const <AssetEntry>[],
    );
    await pumpDialog(tester, fake);

    expect(find.text('BookA'), findsOneWidget);

    await tapDeleteAndConfirm(
      tester,
      rowDeleteIcon: find.byIcon(Icons.delete_outline),
      menuLabel: t.sync_compare_delete_book,
    );

    expect(fake.deletedIds, contains('folderX'));
    expect(fake.deletedFolderFlags['folderX'], isTrue);
    // Optimistic removal: the row is gone after a successful delete.
    expect(find.text('BookA'), findsNothing);
  });

  testWidgets(
      'dictionary row delete calls deleteAsset on remote asset id (not folder)',
      (WidgetTester tester) async {
    const String assetId = '__dictionaries__/JMdict.hibikidict';
    final _FakeSyncBackend fake = _FakeSyncBackend(
      books: const <DriveFile>[],
      dictAssets: const <AssetEntry>[
        AssetEntry(id: assetId, name: 'JMdict.hibikidict'),
      ],
    );
    await pumpDialog(tester, fake);

    expect(find.text('JMdict'), findsOneWidget);

    await tapDeleteAndConfirm(
      tester,
      rowDeleteIcon: find.byIcon(Icons.delete_outline),
      menuLabel: t.sync_compare_delete_dict,
    );

    expect(fake.deletedIds, contains(assetId));
    expect(fake.deletedFolderFlags[assetId], isFalse);
    expect(find.text('JMdict'), findsNothing);
  });

  testWidgets('failed delete keeps the row and surfaces an error',
      (WidgetTester tester) async {
    final _FakeSyncBackend fake = _FakeSyncBackend(
      books: <DriveFile>[const DriveFile(id: 'folderX', name: 'BookA')],
      dictAssets: const <AssetEntry>[],
    )..failDelete = true;
    await pumpDialog(tester, fake);

    await tapDeleteAndConfirm(
      tester,
      rowDeleteIcon: find.byIcon(Icons.delete_outline),
      menuLabel: t.sync_compare_delete_book,
    );

    // deleteAsset was attempted with the right locator...
    expect(fake.deletedIds, contains('folderX'));
    expect(fake.deletedFolderFlags['folderX'], isTrue);
    // ...but the row must survive a failure (no optimistic removal).
    expect(find.text('BookA'), findsOneWidget);
  });

  testWidgets(
      'audiobook row delete removes only the audiobook action, keeps the book row',
      (WidgetTester tester) async {
    final _FakeSyncBackend fake = _FakeSyncBackend(
      books: <DriveFile>[const DriveFile(id: 'folderX', name: 'BookA')],
      dictAssets: const <AssetEntry>[],
    )..withAudio = true;
    await pumpDialog(tester, fake);

    expect(find.text('BookA'), findsOneWidget);

    await tapDeleteAndConfirm(
      tester,
      rowDeleteIcon: find.byIcon(Icons.delete_outline),
      menuLabel: t.sync_compare_delete_audiobook,
    );

    // Deleted the audiobook asset (not a folder).
    expect(fake.deletedIds, contains(_FakeSyncBackend.audioAssetId));
    expect(
      fake.deletedFolderFlags[_FakeSyncBackend.audioAssetId],
      isFalse,
    );
    // The book folder was never touched.
    expect(fake.deletedIds, isNot(contains('folderX')));
    // Unlike a whole-book delete, the row survives — only the audiobook
    // sub-action is cleared (_copyWithoutAudio optimistic refresh).
    expect(find.text('BookA'), findsOneWidget);

    // Re-open the row overflow: the audiobook item is gone, the book item stays.
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text(t.sync_compare_delete_audiobook), findsNothing);
    expect(find.text(t.sync_compare_delete_book), findsOneWidget);
  });
}
