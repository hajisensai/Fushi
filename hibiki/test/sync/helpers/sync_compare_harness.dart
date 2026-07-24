import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 共享测试夹具：`SyncCompareDialog` / `SyncConflictPrompter` 相关的
/// 「compare 冲突面」测试三件套（sync_compare_conflict / sync_compare_dialog_labels /
/// sync_conflict_present）此前逐字复制同一套 backend 双替身 + 种子 helper，此处上移为
/// 唯一真相源。测试语义与断言保持不变，只共享搭建/种子/фake 定义。

/// 内存 [HibikiDatabase]，供 compare 面测试先种书/进度/基线再拉起对话框。
HibikiDatabase memCompareDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// One chapter of 1000 characters keeps fraction math simple: explored chars
/// map linearly to normCharOffset in 0..10000.
const String compareChaptersJson = '[{"characters":1000}]';

/// Backend test double for the compare dialog's baseline-conflict surface.
///
/// Each remote book folder gets a [CompareRemoteBook] entry carrying its progress
/// file metadata (name encodes timestamp+fraction) and payload. The dialog's
/// `_load` reads `listBooks` → per-folder `listSyncFiles` → `getProgressFile`;
/// Apply's manual export reaches `updateProgressFile`. Members not on those
/// paths throw so an unexpected route fails loudly.
class FakeCompareSyncBackend implements SyncBackend {
  FakeCompareSyncBackend({required this.remoteBooks});

  /// title → remote book data (folder id + progress file/payload).
  final Map<String, CompareRemoteBook> remoteBooks;

  /// Captured export writes keyed by folder id, for base-write assertions.
  final Map<String, TtuProgress> exportedByFolder = <String, TtuProgress>{};

  // ── Read methods the dialog's _load path needs ────────────────────
  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async => <DriveFile>[
        for (final MapEntry<String, CompareRemoteBook> e in remoteBooks.entries)
          DriveFile(id: e.value.folderId, name: e.key),
      ];
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}

  @override
  void evictFolderId(String folderId) {}
  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async {
    final CompareRemoteBook? book = _byFolder(folderId);
    if (book == null) return const DriveSyncFiles();
    return DriveSyncFiles(progress: book.progressFile);
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    for (final CompareRemoteBook b in remoteBooks.values) {
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

  CompareRemoteBook? _byFolder(String folderId) {
    for (final CompareRemoteBook b in remoteBooks.values) {
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
class CompareRemoteBook {
  CompareRemoteBook({
    required this.folderId,
    this.progressFile,
    this.payload,
  });

  final String folderId;
  final DriveFile? progressFile;
  final TtuProgress? payload;

  factory CompareRemoteBook.withProgress({
    required String folderId,
    required int timestampMs,
    required double fraction,
  }) {
    final int exploredChars = (fraction * 1000).round();
    return CompareRemoteBook(
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

/// 在 [db] 里种一本 1000 字单章书，返回其 [EpubBookRow]。
Future<EpubBookRow> seedCompareBook(HibikiDatabase db, String title) async {
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/fake/$title.epub',
    extractDir: '/fake/$title',
    chapterCount: 1,
    chaptersJson: compareChaptersJson,
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ));
  return (await db.getAllEpubBooks()).firstWhere((b) => b.title == title);
}

/// 种一条本地阅读位置，其 explored-char 偏移对应 [fraction]（单 1000 字章），
/// 打上 [updatedAt] 时间戳。
Future<void> seedCompareReaderPosition(
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
