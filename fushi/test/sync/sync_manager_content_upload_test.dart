import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_remote_listing.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:path/path.dart' as p;

const String _title = 'Unread Content Book';
const String _chaptersJson = '[{"characters":1000}]';
const Map<String, String> _epubFiles = <String, String>{
  'mimetype': 'application/epub+zip',
  'META-INF/container.xml':
      '<?xml version="1.0"?>'
      '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
      'version="1.0"><rootfiles>'
      '<rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/>'
      '</rootfiles></container>',
  'OEBPS/content.opf':
      '<?xml version="1.0"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="book-id">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:identifier id="book-id">unread-content-book</dc:identifier>'
      '<dc:title>Unread Content Book</dc:title><dc:language>en</dc:language>'
      '<meta property="dcterms:modified">2026-10-20T00:00:00Z</meta>'
      '</metadata><manifest>'
      '<item id="chapter" href="chapter.xhtml" '
      'media-type="application/xhtml+xml"/>'
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" '
      'properties="nav"/></manifest>'
      '<spine><itemref idref="chapter"/></spine></package>',
  'OEBPS/chapter.xhtml':
      '<?xml version="1.0"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
      '<title>Chapter</title></head><body><p>Never opened.</p></body></html>',
  'OEBPS/nav.xhtml':
      '<?xml version="1.0"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml" '
      'xmlns:epub="http://www.idpf.org/2007/ops"><head>'
      '<title>Contents</title></head><body><nav epub:type="toc">'
      '<ol><li><a href="chapter.xhtml">Chapter</a></li></ol>'
      '</nav></body></html>',
};

const Map<String, Object?> _remoteSidecars = <String, Object?>{
  kSyncBookTagsAssetName: <String, Object?>{
    'schemaVersion': 2,
    'tags': <String>['Remote tag'],
    'tagsAddedAt': <String, int>{'Remote tag': 300},
    'tagTombstones': <String, int>{'Removed remote tag': 250},
  },
  kSyncBookCssAssetName: <String, Object?>{
    'schemaVersion': 1,
    'files': <String, Object?>{
      'OEBPS/style.css': <String, Object?>{
        'content': 'body { color: blue; }',
        'deleted': false,
        'updatedAt': 300,
      },
    },
  },
  kSyncMangaReaderAssetName: <String, Object?>{
    'schemaVersion': 1,
    'overrides': <String, Object?>{'readingDirection': 'rtl'},
    'updatedAt': 300,
    'deleted': false,
  },
};

class _ContentUpload {
  const _ContentUpload({
    required this.folderId,
    required this.fileName,
    required this.sourcePath,
    required this.bytes,
  });

  final String folderId;
  final String fileName;
  final String sourcePath;
  final List<int> bytes;
}

/// Like the conflict tests' backend, but keeps remote content and copies the
/// actual temporary EPUB before SyncManager deletes it after the upload.
class _ContentSyncBackend implements SyncBackend {
  SyncFileRef? remoteProgressFile;
  TtuProgress? remoteProgress;
  bool failContentUpload = false;
  bool failFirstUploadRetryably = false;
  bool failRetriedUploadGenerically = false;
  bool loseFirstUploadReply = false;
  int contentUploadAttempts = 0;
  int cacheClearCalls = 0;
  int syncFileListCalls = 0;
  int listChildrenCalls = 0;
  int statsWrites = 0;
  int audioBookWrites = 0;
  final List<String> contentLookups = <String>[];
  final List<TtuProgress> progressWrites = <TtuProgress>[];
  final List<String> jsonWrites = <String>[];
  final List<_ContentUpload> contentUploads = <_ContentUpload>[];
  final Map<String, List<int>> contentFiles = <String, List<int>>{};
  final Map<String, Object?> jsonAssets = Map<String, Object?>.from(
    _remoteSidecars,
  );
  String? _cachedRoot;
  final Map<String, String> _cachedFolders = <String, String>{};

  void seedProgress(int timestamp, double fraction) {
    remoteProgressFile = SyncFileRef(
      id: 'progress-id',
      name: progressFileName(timestamp, fraction),
    );
    remoteProgress = TtuProgress(
      dataId: 0,
      exploredCharCount: (fraction * 1000).round(),
      progress: fraction,
      lastBookmarkModified: timestamp,
    );
  }

  @override
  Future<String> findOrCreateRootFolder() async => _cachedRoot ??= 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async {
    _cachedFolders[bookTitle] = 'folder';
    return 'folder';
  }

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    syncFileListCalls++;
    return SyncFileTrio(
      progress: remoteProgressFile,
      statistics: const SyncFileRef(
        id: 'statistics-id',
        name: 'statistics_1_6_50.json',
      ),
      audioBook: const SyncFileRef(
        id: 'audio-id',
        name: 'audioBook_1_6_50.json',
      ),
    );
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async =>
      remoteProgress ?? (throw StateError('no remote progress seeded'));

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    progressWrites.add(progress);
    remoteProgress = progress;
    remoteProgressFile = SyncFileRef(
      id: 'progress-id',
      name: progressFileName(progress.lastBookmarkModified, progress.progress),
    );
  }

  @override
  Future<SyncFileRef?> findContentFile(String folderId, String fileName) async {
    contentLookups.add(fileName);
    return contentFiles.containsKey(fileName)
        ? SyncFileRef(id: 'content:$fileName', name: fileName)
        : null;
  }

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    SyncTransferProgress? onProgress,
  }) async {
    contentUploadAttempts++;
    if (failContentUpload) {
      throw SyncBackendError('simulated content upload failure');
    }
    if (failFirstUploadRetryably && contentUploadAttempts == 1) {
      throw SyncBackendError(
        'simulated failure before content upload',
        isRetryable: true,
      );
    }
    if (failRetriedUploadGenerically && contentUploadAttempts == 2) {
      throw StateError('simulated generic failure after retry');
    }
    final List<int> bytes = await file.readAsBytes();
    contentUploads.add(
      _ContentUpload(
        folderId: folderId,
        fileName: fileName,
        sourcePath: file.path,
        bytes: bytes,
      ),
    );
    contentFiles[fileName] = bytes;
    if (loseFirstUploadReply && contentUploadAttempts == 1) {
      // The provider stored the file, but the client never received success.
      // A retry must probe the folder again before attempting another upload.
      throw SyncBackendError(
        'simulated lost content upload reply',
        isRetryable: true,
      );
    }
    onProgress?.call(1);
  }

  @override
  Future<void> putJsonAsset(
    String namespaceId,
    String name,
    Object? json,
  ) async {
    jsonWrites.add(name);
    jsonAssets[name] = json;
  }

  @override
  void clearCache() {
    cacheClearCalls++;
    _cachedRoot = null;
    _cachedFolders.clear();
  }

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    _cachedRoot = rootFolderId;
    if (titleToFolderId != null) _cachedFolders.addAll(titleToFolderId);
  }

  @override
  String? get cachedRootFolderId => _cachedRoot;
  @override
  Map<String, String> get cachedFolderIds => _cachedFolders;
  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}
  @override
  void evictFolderId(String folderId) {}
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
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async => const [];
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
  }) async {
    statsWrites++;
  }

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    audioBookWrites++;
  }

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    SyncTransferProgress? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureNamespace(String name) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureFolder(String parentId, String name) async =>
      throw UnimplementedError();

  /// 书文件夹的直接子项：已存在的书文件 + JSON sidecar（无快照时补缺路径列一次）。
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    listChildrenCalls++;
    return <AssetEntry>[
      for (final String name in contentFiles.keys)
        AssetEntry(id: 'content:$name', name: name),
      for (final String name in jsonAssets.keys)
        AssetEntry(id: 'json:$name', name: name),
    ];
  }

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async =>
      throw UnimplementedError();
  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    SyncTransferProgress? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    SyncTransferProgress? onProgress,
  }) async => throw UnimplementedError();
  @override
  Future<Object?> getJsonAsset(String assetId) async =>
      throw UnimplementedError();
}

Future<EpubBookRow> _seedBook(
  FushiDatabase db,
  Directory temporaryDirectory,
) async {
  final Directory extracted = Directory(
    p.join(temporaryDirectory.path, 'extracted'),
  );
  for (final MapEntry<String, String> entry in _epubFiles.entries) {
    final File file = File(p.join(extracted.path, entry.key));
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
  }
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: _title,
      title: _title,
      // Import keeps the source name, not a standalone file. Requiring this path
      // to exist would silently skip the real extracted-book storage model.
      epubPath: p.join(temporaryDirectory.path, 'original.epub'),
      extractDir: extracted.path,
      chapterCount: 1,
      chaptersJson: _chaptersJson,
      importedAt: 1,
    ),
  );
  return (await db.getAllEpubBooks()).single;
}

Future<void> _seedPosition(
  FushiDatabase db,
  EpubBookRow book, {
  required int timestamp,
  required double fraction,
}) => db.upsertReaderPosition(
  ReaderPositionsCompanion(
    bookUid: Value(book.uid),
    sectionIndex: const Value(0),
    normCharOffset: Value((fraction * 10000).round()),
    updatedAt: Value(timestamp),
  ),
);

Future<void> _seedLocalSidecars(FushiDatabase db, EpubBookRow book) async {
  final int tagId = await db.getOrCreateTagByName('Local tag');
  await db.addTagToBook(book.bookKey, tagId);
  await db.upsertBookCss(
    book.uid,
    'OEBPS/style.css',
    'body { color: red; }',
    120,
  );
  await db.setMangaReaderOverride(book.uid, <String, Object?>{
    'readingDirection': 'ltr',
  });
}

void _expectUploadedEpub(_ContentSyncBackend backend) {
  final _ContentUpload upload = backend.contentUploads.single;
  expect(upload.folderId, 'folder');
  expect(upload.fileName, '${sanitizeTtuFilename(_title)}.epub');
  final Archive archive = ZipDecoder().decodeBytes(upload.bytes);
  final Map<String, String> contents = <String, String>{
    for (final ArchiveFile file in archive.files.where(
      (ArchiveFile file) => file.isFile,
    ))
      file.name: utf8.decode(file.content as List<int>),
  };
  expect(
    contents,
    _epubFiles,
    reason: 'the uploaded ZIP must contain the complete EPUB at its root',
  );
  expect(
    File(upload.sourcePath).existsSync(),
    isFalse,
    reason: 'the temporary archive must be cleaned after upload',
  );
}

void _expectNoMetadataWrites(_ContentSyncBackend backend) {
  expect(backend.progressWrites, isEmpty);
  expect(backend.statsWrites, 0);
  expect(backend.audioBookWrites, 0);
  expect(backend.jsonWrites, isEmpty);
  expect(backend.jsonAssets, _remoteSidecars);
}

void main() {
  late FushiDatabase db;
  late Directory temporaryDirectory;
  late EpubBookRow book;
  late _ContentSyncBackend backend;
  late SyncManager manager;
  final String assetKey = sanitizeTtuFilename(_title);

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'fushi_content_sync_test',
    );
    book = await _seedBook(db, temporaryDirectory);
    backend = _ContentSyncBackend();
    manager = SyncManager(db: db, backend: backend);
  });

  tearDown(() async {
    await db.close();
    await temporaryDirectory.delete(recursive: true);
  });

  Future<SyncBookResult> syncBook({
    bool syncContent = true,
    bool importOnly = false,
    SyncDirection? direction,
    RemoteListingSnapshot? listing,
  }) => manager.syncBook(
    book: book,
    direction: direction,
    syncStats: false,
    statsSyncMode: StatisticsSyncMode.merge,
    syncAudioBook: false,
    syncContent: syncContent,
    importOnly: importOnly,
    listing: listing,
  );

  test(
    'sweep uploads an unread EPUB into a metadata-only remote folder',
    () async {
      expect(File(book.epubPath).existsSync(), isFalse);
      expect(await db.getReaderPosition(book.uid), isNull);
      expect(backend.jsonAssets, isNotEmpty);

      final List<SyncBookResult> results = await manager.syncAllBooks(
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
        syncContent: true,
      );

      expect(results.single.direction, SyncResult.synced);
      expect(results.single.error, isNull);
      _expectUploadedEpub(backend);
      _expectNoMetadataWrites(backend);
      expect(await db.getReaderPosition(book.uid), isNull);
      expect(await db.getSyncBaseline(assetKey, 'progress'), isNull);
    },
  );

  test(
    'equal progress still repairs missing content without exporting progress',
    () async {
      await _seedPosition(db, book, timestamp: 100, fraction: 0.4);
      await db.setSyncBaseline(assetKey, 'progress', 100);
      backend.seedProgress(100, 0.4);
      final TtuProgress remoteBefore = backend.remoteProgress!;

      final SyncBookResult result = await syncBook();

      expect(result.direction, SyncResult.synced);
      expect(result.error, isNull);
      _expectUploadedEpub(backend);
      _expectNoMetadataWrites(backend);
      expect(backend.remoteProgress, same(remoteBefore));
      final ReaderPositionRow position = (await db.getReaderPosition(
        book.uid,
      ))!;
      expect(position.updatedAt, 100);
      expect(position.normCharOffset, 4000);
      expect(await db.getSyncBaseline(assetKey, 'progress'), 100);
    },
  );

  test(
    'progress conflict repairs content but preserves progress and sidecars',
    () async {
      await _seedPosition(db, book, timestamp: 120, fraction: 0.6);
      await db.setSyncBaseline(assetKey, 'progress', 50);
      await _seedLocalSidecars(db, book);
      backend.seedProgress(100, 0.4);
      final TtuProgress remoteBefore = backend.remoteProgress!;
      final List<BookCustomCssRow> localCssBefore = await db.getBookCssRows(
        book.uid,
      );
      final MangaReaderOverrideRow? localReaderBefore = await db
          .getMangaReaderOverride(book.uid);
      final Map<String, int> localTagsBefore = await db.bookTagAddedAtByName(
        book.bookKey,
      );

      final SyncBookResult result = await syncBook();

      expect(result.direction, SyncResult.conflict);
      expect(result.error, isNull);
      expect(result.conflictAssetKey, assetKey);
      expect(result.conflictDimension, 'progress');
      expect(result.conflictLocalVersion, 120);
      expect(result.conflictRemoteVersion, 100);
      _expectUploadedEpub(backend);
      _expectNoMetadataWrites(backend);
      expect(backend.remoteProgress, same(remoteBefore));
      final ReaderPositionRow position = (await db.getReaderPosition(
        book.uid,
      ))!;
      expect(position.updatedAt, 120);
      expect(position.normCharOffset, 6000);
      expect(await db.getSyncBaseline(assetKey, 'progress'), 50);
      expect(await db.getBookCssRows(book.uid), localCssBefore);
      expect(await db.getMangaReaderOverride(book.uid), localReaderBefore);
      expect(await db.bookTagAddedAtByName(book.bookKey), localTagsBefore);
    },
  );

  test('importing progress also uploads the missing local EPUB', () async {
    await _seedPosition(db, book, timestamp: 50, fraction: 0.3);
    await db.setSyncBaseline(assetKey, 'progress', 50);
    await _seedLocalSidecars(db, book);
    backend.seedProgress(100, 0.6);
    final TtuProgress remoteBefore = backend.remoteProgress!;

    final SyncBookResult result = await syncBook();

    expect(result.direction, SyncResult.imported);
    expect(result.error, isNull);
    _expectUploadedEpub(backend);
    _expectNoMetadataWrites(backend);
    expect(backend.remoteProgress, same(remoteBefore));
    final ReaderPositionRow position = (await db.getReaderPosition(book.uid))!;
    expect(position.updatedAt, 100);
    expect(position.normCharOffset, 6000);
    expect(await db.getSyncBaseline(assetKey, 'progress'), 100);
  });

  for (final String state in <String>[
    'unread',
    'synced',
    'conflict',
    'import',
    'export',
  ]) {
    test('importOnly never uploads content or metadata ($state)', () async {
      await _seedLocalSidecars(db, book);
      if (state != 'unread') {
        await _seedPosition(
          db,
          book,
          timestamp: state == 'import' ? 50 : 100,
          fraction: 0.4,
        );
        await db.setSyncBaseline(assetKey, 'progress', 50);
        backend.seedProgress(
          state == 'export' ? 50 : (state == 'conflict' ? 120 : 100),
          0.4,
        );
      }

      final SyncBookResult result = await syncBook(importOnly: true);

      expect(result.error, isNull);
      expect(backend.contentUploadAttempts, 0);
      expect(backend.contentUploads, isEmpty);
      _expectNoMetadataWrites(backend);
      if (state == 'import') {
        expect(result.direction, SyncResult.imported);
        expect((await db.getReaderPosition(book.uid))!.updatedAt, 100);
      }
    });
  }

  test('disabled content sync does not upload files or sidecars', () async {
    await _seedLocalSidecars(db, book);
    await _seedPosition(db, book, timestamp: 120, fraction: 0.6);

    final SyncBookResult result = await syncBook(syncContent: false);

    expect(result.direction, SyncResult.exported);
    expect(result.error, isNull);
    expect(backend.progressWrites.single.lastBookmarkModified, 120);
    expect(backend.contentUploadAttempts, 0);
    expect(backend.jsonWrites, isEmpty);
    expect(backend.jsonAssets, _remoteSidecars);
  });

  test('existing remote content is not overwritten', () async {
    final String fileName = '${sanitizeTtuFilename(_title)}.epub';
    final List<int> originalBytes = <int>[1, 2, 3, 4];
    backend.contentFiles[fileName] = originalBytes;

    final SyncBookResult result = await syncBook();

    expect(result.direction, SyncResult.synced);
    expect(result.error, isNull);
    expect(backend.contentUploadAttempts, 0);
    expect(backend.contentFiles[fileName], same(originalBytes));
    _expectNoMetadataWrites(backend);
  });

  test('snapshot with EPUB avoids content probes and uploads', () async {
    final String fileName = '${sanitizeTtuFilename(_title)}.epub';
    final List<int> originalBytes = <int>[1, 2, 3, 4];
    backend.contentFiles[fileName] = originalBytes;
    final RemoteListingSnapshot listing = RemoteListingSnapshot(
      <String, List<AssetEntry>>{
        assetKey: <AssetEntry>[
          for (final String name in _remoteSidecars.keys)
            AssetEntry(id: 'sidecar:$name', name: name),
          AssetEntry(id: 'content:$fileName', name: fileName),
        ],
      },
    );

    final SyncBookResult result = await syncBook(listing: listing);

    expect(result.direction, SyncResult.synced);
    expect(result.error, isNull);
    expect(backend.syncFileListCalls, 0);
    expect(backend.contentLookups, isEmpty);
    expect(backend.contentUploadAttempts, 0);
    expect(backend.contentFiles[fileName], same(originalBytes));
    _expectNoMetadataWrites(backend);
  });

  test(
    'metadata-only snapshot still probes and uploads missing EPUB',
    () async {
      final RemoteListingSnapshot listing = RemoteListingSnapshot(
        <String, List<AssetEntry>>{
          assetKey: <AssetEntry>[
            for (final String name in _remoteSidecars.keys)
              AssetEntry(id: 'sidecar:$name', name: name),
          ],
        },
      );

      final SyncBookResult result = await syncBook(listing: listing);

      expect(result.direction, SyncResult.synced);
      expect(result.error, isNull);
      expect(backend.syncFileListCalls, 0);
      expect(backend.contentLookups, <String>[
        '${sanitizeTtuFilename(_title)}.epub',
      ]);
      expect(backend.contentUploadAttempts, 1);
      _expectUploadedEpub(backend);
      _expectNoMetadataWrites(backend);
      expect(await db.getReaderPosition(book.uid), isNull);
      expect(await db.getSyncBaseline(assetKey, 'progress'), isNull);
    },
  );

  test(
    'a second unread-book sweep does not upload the same EPUB again',
    () async {
      for (int sweep = 0; sweep < 2; sweep++) {
        final List<SyncBookResult> results = await manager.syncAllBooks(
          syncStats: false,
          statsSyncMode: StatisticsSyncMode.merge,
          syncAudioBook: false,
          syncContent: true,
        );
        expect(results.single.direction, SyncResult.synced);
        expect(results.single.error, isNull);
      }

      expect(backend.contentUploadAttempts, 1);
      _expectUploadedEpub(backend);
      _expectNoMetadataWrites(backend);
      expect(await db.getReaderPosition(book.uid), isNull);
      expect(await db.getSyncBaseline(assetKey, 'progress'), isNull);
    },
  );

  test(
    'content upload failure is reported as contentError, not swallowed',
    () async {
      backend.failContentUpload = true;

      final SyncBookResult result = await syncBook();

      // 进度判定（未读 = synced）照实；补传失败单独上报，编排器把它计入报告错误。
      expect(result.direction, SyncResult.synced);
      expect(result.error, isNull);
      expect(result.contentError, 'simulated content upload failure');
      expect(classifySyncApply(result), SyncApplyOutcome.noop);
      expect(backend.contentUploadAttempts, 1);
      expect(backend.contentUploads, isEmpty);
      expect(backend.contentFiles, isEmpty);
      _expectNoMetadataWrites(backend);
      expect(await db.getReaderPosition(book.uid), isNull);
      expect(await db.getSyncBaseline(assetKey, 'progress'), isNull);
    },
  );

  test('content failure retains the unresolved progress conflict', () async {
    await _seedPosition(db, book, timestamp: 120, fraction: 0.6);
    await db.setSyncBaseline(assetKey, 'progress', 50);
    await _seedLocalSidecars(db, book);
    backend.seedProgress(100, 0.4);
    backend.failContentUpload = true;
    final ReaderPositionRow localBefore = (await db.getReaderPosition(
      book.uid,
    ))!;
    final TtuProgress remoteBefore = backend.remoteProgress!;
    final SyncFileRef remoteFileBefore = backend.remoteProgressFile!;

    final SyncBookResult result = await syncBook();

    expect(result.direction, SyncResult.conflict);
    expect(result.conflictAssetKey, assetKey);
    expect(result.conflictDimension, 'progress');
    expect(result.conflictLocalVersion, 120);
    expect(result.conflictRemoteVersion, 100);
    expect(result.error, isNull);
    expect(result.contentError, 'simulated content upload failure');
    expect(classifySyncApply(result), SyncApplyOutcome.noop);
    expect(backend.contentUploadAttempts, 1);
    expect(backend.cacheClearCalls, 0);
    expect(backend.contentUploads, isEmpty);
    expect(backend.contentFiles, isEmpty);
    _expectNoMetadataWrites(backend);
    expect(await db.getReaderPosition(book.uid), localBefore);
    expect(backend.remoteProgress, same(remoteBefore));
    expect(backend.remoteProgressFile, same(remoteFileBefore));
    expect(await db.getSyncBaseline(assetKey, 'progress'), 50);
  });

  test(
    'retryable failure before upload retries and publishes the EPUB',
    () async {
      backend.failFirstUploadRetryably = true;

      final SyncBookResult result = await syncBook();

      expect(result.direction, SyncResult.synced);
      expect(result.error, isNull);
      expect(backend.cacheClearCalls, 1);
      expect(backend.contentUploadAttempts, 2);
      expect(backend.contentLookups, <String>[
        '${sanitizeTtuFilename(_title)}.epub',
        '${sanitizeTtuFilename(_title)}.epub',
      ]);
      _expectUploadedEpub(backend);
      _expectNoMetadataWrites(backend);
      expect(await db.getReaderPosition(book.uid), isNull);
      expect(await db.getSyncBaseline(assetKey, 'progress'), isNull);
    },
  );

  test(
    'generic failure during retry returns the unresolved progress conflict',
    () async {
      await _seedPosition(db, book, timestamp: 120, fraction: 0.6);
      await db.setSyncBaseline(assetKey, 'progress', 50);
      await _seedLocalSidecars(db, book);
      backend.seedProgress(100, 0.4);
      backend.failFirstUploadRetryably = true;
      backend.failRetriedUploadGenerically = true;
      final ReaderPositionRow localBefore = (await db.getReaderPosition(
        book.uid,
      ))!;
      final TtuProgress remoteBefore = backend.remoteProgress!;
      final SyncFileRef remoteFileBefore = backend.remoteProgressFile!;

      // A generic exception thrown inside the retry catch must be converted
      // to a result too; sibling catches on the outer try cannot handle it.
      final SyncBookResult result = await syncBook();

      expect(result.direction, SyncResult.conflict);
      expect(result.conflictAssetKey, assetKey);
      expect(result.conflictDimension, 'progress');
      expect(result.conflictLocalVersion, 120);
      expect(result.conflictRemoteVersion, 100);
      expect(result.error, isNull);
      expect(
        result.contentError,
        contains('simulated generic failure after retry'),
      );
      expect(classifySyncApply(result), SyncApplyOutcome.noop);
      expect(backend.cacheClearCalls, 1);
      expect(backend.contentUploadAttempts, 2);
      expect(backend.contentUploads, isEmpty);
      expect(backend.contentFiles, isEmpty);
      _expectNoMetadataWrites(backend);
      expect(await db.getReaderPosition(book.uid), localBefore);
      expect(backend.remoteProgress, same(remoteBefore));
      expect(backend.remoteProgressFile, same(remoteFileBefore));
      expect(await db.getSyncBaseline(assetKey, 'progress'), 50);
    },
  );

  test(
    'lost upload reply rechecks remote content without uploading twice',
    () async {
      backend.loseFirstUploadReply = true;

      final SyncBookResult result = await syncBook();

      expect(result.direction, SyncResult.synced);
      expect(result.error, isNull);
      expect(backend.cacheClearCalls, 1);
      expect(backend.contentUploadAttempts, 1);
      // 重试时没有快照：列一次目录就看到已存好的 EPUB，不再探针、不再上传。
      expect(backend.listChildrenCalls, 2);
      expect(backend.contentLookups, <String>[
        '${sanitizeTtuFilename(_title)}.epub',
      ]);
      _expectUploadedEpub(backend);
      _expectNoMetadataWrites(backend);
      expect(await db.getReaderPosition(book.uid), isNull);
      expect(await db.getSyncBaseline(assetKey, 'progress'), isNull);
    },
  );

  for (final bool importing in <bool>[false, true]) {
    test('content failure preserves the already landed progress '
        '${importing ? 'import' : 'export'} and baseline', () async {
      await _seedPosition(
        db,
        book,
        timestamp: importing ? 50 : 120,
        fraction: importing ? 0.3 : 0.6,
      );
      await db.setSyncBaseline(assetKey, 'progress', 50);
      backend.seedProgress(importing ? 100 : 50, importing ? 0.6 : 0.3);
      backend.failContentUpload = true;

      final SyncBookResult result = await syncBook();

      // 进度已落地：结果照实为导入 / 导出（对比弹窗按它判「已应用」），上传失败另报。
      expect(
        result.direction,
        importing ? SyncResult.imported : SyncResult.exported,
      );
      expect(result.error, isNull);
      expect(result.contentError, 'simulated content upload failure');
      expect(classifySyncApply(result), SyncApplyOutcome.applied);
      expect(backend.contentUploadAttempts, 1);
      expect(backend.contentUploads, isEmpty);
      final int landedTimestamp = importing ? 100 : 120;
      final ReaderPositionRow position = (await db.getReaderPosition(
        book.uid,
      ))!;
      expect(position.updatedAt, landedTimestamp);
      expect(position.normCharOffset, 6000);
      expect(backend.remoteProgress!.lastBookmarkModified, landedTimestamp);
      expect(backend.remoteProgress!.exploredCharCount, 600);
      expect(await db.getSyncBaseline(assetKey, 'progress'), landedTimestamp);
      expect(backend.progressWrites.length, importing ? 0 : 1);
      expect(backend.jsonWrites, isEmpty);
      expect(backend.jsonAssets, _remoteSidecars);
    });
  }

  test('normal progress export still publishes local sidecars', () async {
    await _seedPosition(db, book, timestamp: 120, fraction: 0.6);
    await _seedLocalSidecars(db, book);

    final SyncBookResult result = await syncBook();

    expect(result.direction, SyncResult.exported);
    expect(result.error, isNull);
    expect(backend.progressWrites.single.lastBookmarkModified, 120);
    expect(await db.getSyncBaseline(assetKey, 'progress'), 120);
    _expectUploadedEpub(backend);
    expect(backend.jsonWrites, unorderedEquals(_remoteSidecars.keys));
    final Map<String, Object?> tags =
        backend.jsonAssets[kSyncBookTagsAssetName]! as Map<String, Object?>;
    expect(tags['tags'], <String>['Local tag']);
    final Map<String, Object?> css =
        backend.jsonAssets[kSyncBookCssAssetName]! as Map<String, Object?>;
    expect(css['files'], <String, Object?>{
      'OEBPS/style.css': <String, Object?>{
        'content': 'body { color: red; }',
        'deleted': false,
        'updatedAt': 120,
      },
    });
    final Map<String, Object?> reader =
        backend.jsonAssets[kSyncMangaReaderAssetName]! as Map<String, Object?>;
    expect(reader['overrides'], <String, Object?>{'readingDirection': 'ltr'});
  });

  // 书文件夹元数据只随导出写：未读的书补上了 EPUB，下载端却永远读不到标签 / CSS /
  // 漫画阅读设置。补缺路径只写远端缺的，已有的不覆盖（覆盖仍只归导出方向）。
  test('unread book fills missing remote sidecars, never overwrites', () async {
    await _seedLocalSidecars(db, book);
    backend.jsonAssets
      ..remove(kSyncBookTagsAssetName)
      ..remove(kSyncMangaReaderAssetName);

    final SyncBookResult result = await syncBook();

    expect(result.direction, SyncResult.synced);
    expect(result.contentError, isNull);
    _expectUploadedEpub(backend);
    expect(backend.jsonWrites.toSet(), <String>{
      kSyncBookTagsAssetName,
      kSyncMangaReaderAssetName,
    });
    expect(
      backend.jsonAssets[kSyncBookCssAssetName],
      _remoteSidecars[kSyncBookCssAssetName],
      reason: 'the remote CSS sidecar already existed and must stay as is',
    );
    expect(backend.progressWrites, isEmpty);
  });

  // 没有列举快照（WebDAV / FTP / 单本同步）时每本书列一次目录，而不是逐个文件探针。
  test(
    'without a snapshot one folder listing replaces per-file probes',
    () async {
      backend.contentFiles['${sanitizeTtuFilename(_title)}.epub'] = <int>[1];

      final SyncBookResult result = await syncBook();

      expect(result.direction, SyncResult.synced);
      expect(backend.listChildrenCalls, 1);
      expect(backend.contentLookups, isEmpty);
      expect(backend.contentUploadAttempts, 0);
    },
  );

  // 书文件夹里的原始有声书音频没有任何读取方（下载端只认 .epub / .fushiaudio），
  // 有声书音频由 .fushiaudio 包负责：补缺路径不再往书文件夹传音频。
  test('book folder repair never uploads raw audiobook audio', () async {
    final File audio = File(p.join(temporaryDirectory.path, 'ch1.mp3'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    await db.upsertAudiobook(
      AudiobooksCompanion.insert(
        bookKey: book.bookKey,
        alignmentFormat: 'srt',
        alignmentPath: 'alignment.srt',
        audioPathsJson: Value(jsonEncode(<String>[audio.path])),
      ),
    );

    await syncBook();

    expect(
      backend.contentUploads.map((_ContentUpload u) => u.fileName),
      <String>['${sanitizeTtuFilename(_title)}.epub'],
    );
  });
}
