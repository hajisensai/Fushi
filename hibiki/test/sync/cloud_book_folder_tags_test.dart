import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart' show kSyncBookTagsAssetName;
import 'package:hibiki/src/sync/sync_orchestrator.dart'
    show
        importRemoteBookFolder,
        kSyncAudiobookAssetName,
        parseTagSidecar,
        parseBookCssSidecar;
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/sync_file_ref.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1165: cloud per-book folder tags.json sidecar round-trip + rebuild.
HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

Uint8List _buildMinimalEpub(String title) {
  final Archive archive = Archive();
  void add(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add(
      'META-INF/container.xml',
      '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
          '  <rootfiles>\n'
          '    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\n'
          '  </rootfiles>\n'
          '</container>\n');
  add(
      'OEBPS/content.opf',
      '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">\n'
          '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
          '    <dc:title>$title</dc:title>\n'
          '  </metadata>\n'
          '  <manifest>\n'
          '    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>\n'
          '  </manifest>\n'
          '  <spine>\n'
          '    <itemref idref="chapter"/>\n'
          '  </spine>\n'
          '</package>\n');
  add(
      'OEBPS/chapter.xhtml',
      '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<html xmlns="http://www.w3.org/1999/xhtml">\n'
          '  <head><title>Chapter</title></head>\n'
          '  <body><p>Hello.</p></body>\n'
          '</html>\n');

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// Cloud book-folder fake backend: serves a parseable .epub plus an optional
/// tags.json sidecar. getAsset writes a real EPUB; getJsonAsset returns sidecar.
class _FakeBookFolderBackend implements SyncBackend {
  _FakeBookFolderBackend({
    required this.bookTitle,
    required this.folderId,
    required this.sidecarJson,
    this.includeSidecarEntry = true,
    this.includeAudiobookEntry = false,
  });

  final String bookTitle;
  final String folderId;
  final Object? sidecarJson;
  final bool includeSidecarEntry;
  final bool includeAudiobookEntry;

  /// getAsset 请求过的 assetId（供断言云有声书 pull 是否被触达）。
  final List<String> requestedAssetIds = <String>[];

  static const String epubAssetId = 'epubAsset1';
  static const String sidecarAssetId = 'tagsSidecar1';
  static const String audiobookAssetId = 'audioAsset1';

  @override
  Future<List<AssetEntry>> listChildren(String id) async {
    if (id != folderId) return const <AssetEntry>[];
    return <AssetEntry>[
      const AssetEntry(id: epubAssetId, name: 'book.epub'),
      if (includeSidecarEntry)
        const AssetEntry(id: sidecarAssetId, name: kSyncBookTagsAssetName),
      if (includeAudiobookEntry)
        const AssetEntry(id: audiobookAssetId, name: kSyncAudiobookAssetName),
    ];
  }

  @override
  Future<void> getAsset(String assetId, File destination,
      {void Function(double progress)? onProgress}) async {
    requestedAssetIds.add(assetId);
    // 有声书资产：写非法包字节，让 importAudioDatabasePackage 抛错（被
    // _pullRemoteFolderAudiobook 吞掉）——本测试只验证「下载路径是否触达该资产」。
    if (assetId == audiobookAssetId) {
      await destination.writeAsBytes(<int>[0, 1, 2, 3]);
      return;
    }
    await destination.writeAsBytes(_buildMinimalEpub(bookTitle));
  }

  @override
  Future<Object?> getJsonAsset(String assetId) async {
    if (assetId == sidecarAssetId) return sidecarJson;
    return null;
  }

  @override
  Future<String> findOrCreateRootFolder() async => throw UnimplementedError();
  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async =>
      throw UnimplementedError();
  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) =>
      throw UnimplementedError();
  @override
  void evictFolderId(String folderId) => throw UnimplementedError();
  @override
  Future<SyncFileTrio> listSyncFiles(String f) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureNamespace(String name) async =>
      throw UnimplementedError();
  @override
  void restoreCache(
          {String? rootFolderId, Map<String, String>? titleToFolderId}) =>
      throw UnimplementedError();
  @override
  String? get cachedRootFolderId => throw UnimplementedError();
  @override
  Map<String, String> get cachedFolderIds => throw UnimplementedError();
  @override
  Future<bool> get isAuthenticated async => throw UnimplementedError();
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
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      throw UnimplementedError();
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
  Future<SyncFileRef?> findContentFile(
          String folderId, String fileName) async =>
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
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      throw UnimplementedError();
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async =>
      throw UnimplementedError();
  @override
  void clearCache() => throw UnimplementedError();
}

Future<String> _importOnce(
  HibikiDatabase db,
  _FakeBookFolderBackend backend,
  Directory tempDir,
) async {
  final bool imported = await importRemoteBookFolder(
    db: db,
    backend: backend,
    folderId: backend.folderId,
    tempDir: tempDir,
  );
  expect(imported, isTrue);
  final List<EpubBookRow> books = await db.getAllEpubBooks();
  expect(books, hasLength(1));
  return books.single.bookKey;
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_cloud_book_tags_pp');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    try {
      if (pathProviderDir.existsSync()) {
        pathProviderDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  Directory freshTemp() {
    final Directory d =
        Directory.systemTemp.createTempSync('hibiki_cloud_book_tags_tmp');
    addTearDown(() {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    });
    return d;
  }

  test('sidecar tags round-trip rebuilt by name on the downloading device',
      () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final _FakeBookFolderBackend backend = _FakeBookFolderBackend(
      bookTitle: 'CloudTaggedBook',
      folderId: 'folderA',
      sidecarJson: <String, Object?>{
        'schemaVersion': 1,
        'tags': <String>['听力', 'N2'],
      },
    );

    final String bookKey = await _importOnce(db, backend, freshTemp());
    expect(bookKey, sanitizeTtuFilename('CloudTaggedBook'));

    final Set<String> names = (await db.getTagsForBook(bookKey))
        .map((BookTagRow t) => t.name)
        .toSet();
    expect(names, <String>{'听力', 'N2'});
  });

  test('missing tags.json (legacy) imports fine with no tags and no throw',
      () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final _FakeBookFolderBackend backend = _FakeBookFolderBackend(
      bookTitle: 'LegacyNoSidecar',
      folderId: 'folderB',
      sidecarJson: null,
      includeSidecarEntry: false,
    );

    final String bookKey = await _importOnce(db, backend, freshTemp());
    expect(await db.getTagsForBook(bookKey), isEmpty);
    expect(await db.getAllTags(), isEmpty);
  });

  test('existing same-name tag on downloader is reused by name (no duplicate)',
      () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final int existingId = await db.createTag('听力', 0xFF010203);

    final _FakeBookFolderBackend backend = _FakeBookFolderBackend(
      bookTitle: 'ReuseTagBook',
      folderId: 'folderC',
      sidecarJson: <String, Object?>{
        'schemaVersion': 1,
        'tags': <String>['听力'],
      },
    );

    final String bookKey = await _importOnce(db, backend, freshTemp());

    final List<BookTagRow> all = await db.getAllTags();
    expect(all, hasLength(1));
    expect(all.single.id, existingId);
    expect(all.single.colorValue, 0xFF010203);

    final List<BookTagRow> mapped = await db.getTagsForBook(bookKey);
    expect(mapped, hasLength(1));
    expect(mapped.single.id, existingId);
  });

  test('malformed sidecar degrades safely to empty tags without throwing',
      () async {
    final List<Object?> malformedCases = <Object?>[
      <String, Object?>{'schemaVersion': 1},
      <String, Object?>{'tags': 'oops'},
      <Object?>['听力'],
      'not json at all',
    ];
    for (int i = 0; i < malformedCases.length; i++) {
      final Object? malformed = malformedCases[i];
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final _FakeBookFolderBackend backend = _FakeBookFolderBackend(
        bookTitle: 'Malformed$i',
        folderId: 'folderD$i',
        sidecarJson: malformed,
      );
      final String bookKey = await _importOnce(db, backend, freshTemp());
      expect(await db.getTagsForBook(bookKey), isEmpty,
          reason: 'malformed sidecar $malformed must degrade to empty tags');
      expect(await db.getAllTags(), isEmpty);
    }
  });

  // ── 云后端有声书 pull（修复「只上传拿不回」缺口）──────────────────────────────
  test('提供 audioDatabaseRoot 时下载远端书文件夹会补拉 audiobook.hibikiaudio', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final _FakeBookFolderBackend backend = _FakeBookFolderBackend(
      bookTitle: 'BookWithAudio',
      folderId: 'folderAudio',
      sidecarJson: null,
      includeSidecarEntry: false,
      includeAudiobookEntry: true,
    );
    final Directory audioRoot = freshTemp();

    final bool imported = await importRemoteBookFolder(
      db: db,
      backend: backend,
      folderId: backend.folderId,
      tempDir: freshTemp(),
      audioDatabaseRoot: audioRoot,
    );

    expect(imported, isTrue); // EPUB 导入成功
    expect(await db.getAllEpubBooks(), hasLength(1));
    // 关键：下载路径触达了有声书资产（此前只找 .epub、拿不回音频）。
    expect(backend.requestedAssetIds,
        contains(_FakeBookFolderBackend.audiobookAssetId));
  });

  test('未提供 audioDatabaseRoot 时不拉 audiobook.hibikiaudio（保持旧行为）', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final _FakeBookFolderBackend backend = _FakeBookFolderBackend(
      bookTitle: 'BookAudioSkipped',
      folderId: 'folderAudioSkip',
      sidecarJson: null,
      includeSidecarEntry: false,
      includeAudiobookEntry: true,
    );

    final bool imported = await importRemoteBookFolder(
      db: db,
      backend: backend,
      folderId: backend.folderId,
      tempDir: freshTemp(),
      // audioDatabaseRoot 缺省 null
    );

    expect(imported, isTrue);
    expect(backend.requestedAssetIds,
        isNot(contains(_FakeBookFolderBackend.audiobookAssetId)),
        reason: '未注入 audioDatabaseRoot 时绝不触达有声书资产（向后兼容）');
  });

  // ── parseTagSidecar：v1/v2 LWW 输入解析（tags 稳健档）──────────────────────────
  group('parseTagSidecar', () {
    test('v2 带 tagsAddedAt + tagTombstones 直接用', () {
      final parsed = parseTagSidecar(<String, Object?>{
        'schemaVersion': 2,
        'tags': <String>['听力'],
        'tagsAddedAt': <String, Object?>{'听力': 100},
        'tagTombstones': <String, Object?>{'N2': 200},
      });
      expect(parsed.addedAt, <String, int>{'听力': 100});
      expect(parsed.tombstones, <String, int>{'N2': 200});
    });

    test('v1 只有 tags 名单 → 合成 addedAt=1、无墓碑（向后兼容只增）', () {
      final parsed = parseTagSidecar(<String, Object?>{
        'schemaVersion': 1,
        'tags': <String>['听力', 'N2'],
      });
      expect(parsed.addedAt, <String, int>{'听力': 1, 'N2': 1});
      expect(parsed.tombstones, isEmpty);
    });

    test('数字串值容忍 + 空名/坏字段跳过；非 Map 安全降级为空', () {
      final parsed = parseTagSidecar(<String, Object?>{
        'tagsAddedAt': <String, Object?>{'A': '300', '': 5, 'B': 'x'},
        'tagTombstones': <String, Object?>{'C': 400},
      });
      expect(parsed.addedAt, <String, int>{'A': 300});
      expect(parsed.tombstones, <String, int>{'C': 400});
      final empty = parseTagSidecar('not json');
      expect(empty.addedAt, isEmpty);
      expect(empty.tombstones, isEmpty);
    });
  });

  // ── parseBookCssSidecar：per-book CSS sidecar 解析 ──────────────────────────
  group('parseBookCssSidecar', () {
    test('files 映射解析出 content/deleted/updatedAt', () {
      final parsed = parseBookCssSidecar(<String, Object?>{
        'schemaVersion': 1,
        'files': <String, Object?>{
          'style.css': <String, Object?>{
            'content': 'body{color:red}',
            'deleted': false,
            'updatedAt': 100,
          },
          'reset.css': <String, Object?>{
            'content': '',
            'deleted': true,
            'updatedAt': 200,
          },
        },
      });
      expect(parsed['style.css']!.content, 'body{color:red}');
      expect(parsed['style.css']!.deleted, isFalse);
      expect(parsed['style.css']!.updatedAt, 100);
      expect(parsed['reset.css']!.deleted, isTrue);
      expect(parsed['reset.css']!.updatedAt, 200);
    });

    test('缺 updatedAt / 空 rel / 非 Map 一律安全跳过或返空', () {
      final parsed = parseBookCssSidecar(<String, Object?>{
        'files': <String, Object?>{
          'a.css': <String, Object?>{'content': 'x'}, // 缺 updatedAt
          '': <String, Object?>{'content': 'y', 'updatedAt': 1}, // 空 rel
          'b.css': 'not-a-map',
        },
      });
      expect(parsed, isEmpty);
      expect(parseBookCssSidecar('not json'), isEmpty);
      expect(parseBookCssSidecar(<String, Object?>{'files': 'oops'}), isEmpty);
    });
  });
}
