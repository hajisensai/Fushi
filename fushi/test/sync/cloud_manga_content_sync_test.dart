import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/sync/manga_sync_package.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart'
    show importRemoteBookFolder;
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

// 云盘同步后端的漫画内容通道（互联侧早已支持，云盘侧此前完全缺失）：
//
// - push：`_exportContentIfMissing` 恒调 repackageExtractedEpub，漫画书目录没有
//   EPUB 根 → 恒返回 false → 漫画在**所有**云盘后端静默永不上传；
// - pull：`importRemoteBookFolder` 恒走 EpubImporter，包在云上也导不回来。
//
// 契约与互联通道一致：漫画包与 EPUB 共用同一个 `<title>.epub` 资产名，导入侧按
// **内容**（zip 根 manga.json）嗅探分流，扩展名不参与判定。这两条用例分别钉死
// 上传方向「打的是漫画包」与下载方向「落库成 format=manga 的漫画」。

/// 造一个真实漫画书目录（根含 manga.json + 页图），即磁盘上的漫画布局。
Directory _mangaBookDir({int pages = 2}) {
  final Directory dir = Directory.systemTemp.createTempSync('hbk_cloud_manga');
  final Directory images = Directory(p.join(dir.path, 'images'))..createSync();
  final List<Map<String, Object?>> pageJson = <Map<String, Object?>>[];
  for (int i = 1; i <= pages; i++) {
    File(p.join(images.path, 'p$i.jpg'))
        .writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, i]);
    pageJson.add(<String, Object?>{
      'url': 'images/p$i.jpg',
      'width': 800,
      'height': 1200,
      'blocks': <Object?>[],
    });
  }
  File(p.join(dir.path, kMangaPackageMarker))
      .writeAsStringSync(jsonEncode(<String, Object?>{'pages': pageJson}));
  return dir;
}

/// 记录云盘 push 侧真正上传了什么（内容字节在回调里立刻读走——上传方在 finally
/// 里删临时目录，晚读必然拿不到）。
class _RecordingBackend implements SyncBackend {
  static const String root = 'ROOT/';

  /// 上传过的 (fileName, 内容字节)，顺序即上传顺序。
  final List<({String fileName, Uint8List bytes})> uploads =
      <({String fileName, Uint8List bytes})>[];

  @override
  Future<String> findOrCreateRootFolder() async => root;

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async =>
      '$rootFolderId${sanitizeTtuFilename(bookTitle)}/';

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async =>
      const SyncFileTrio();

  @override
  Future<SyncFileRef?> findContentFile(
          String folderId, String fileName) async =>
      null; // 远端还没有内容资产 → push 侧必须打包上传。

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {
    uploads.add((fileName: fileName, bytes: file.readAsBytesSync()));
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {}

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
  Future<void> putJsonAsset(
      String namespaceId, String name, Object? json) async {}

  // ── Cache ───────────────────────────────────────────────────────────
  @override
  void clearCache() {}
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  String? get cachedRootFolderId => null;
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  void evictFolderId(String folderId) {}
  @override
  void cacheBookFolderIds(List<SyncFileRef> folders) {}

  // ── 其余成员：走到即大声失败 ────────────────────────────────────────
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected backend call: '
          '${invocation.memberName}');
}

/// 云盘 pull 侧：书文件夹里只有一个 `<title>.epub`，其**内容**由 [assetBytes] 决定
/// （漫画包 or 真 EPUB）——导入侧必须按内容分流，不能看扩展名。
class _FolderBackend implements SyncBackend {
  _FolderBackend({required this.folderId, required this.assetName});

  final String folderId;
  final String assetName;
  late final Uint8List assetBytes;

  static const String assetId = 'content1';

  @override
  Future<List<AssetEntry>> listChildren(String id) async => id == folderId
      ? <AssetEntry>[AssetEntry(id: assetId, name: assetName)]
      : const <AssetEntry>[];

  @override
  Future<void> getAsset(String id, File destination,
      {void Function(double progress)? onProgress}) async {
    await destination.writeAsBytes(assetBytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected backend call: '
          '${invocation.memberName}');
}

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<EpubBookRow> _insertBook(
  FushiDatabase db, {
  required String title,
  required String extractDir,
  required BookFormat format,
}) async {
  final String bookKey = sanitizeTtuFilename(title);
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: bookKey,
    title: title,
    epubPath: 'book.epub',
    extractDir: extractDir,
    chapterCount: 1,
    chaptersJson: '[]',
    importedAt: DateTime.now().millisecondsSinceEpoch,
    format: Value(format.dbValue),
  ));
  return (await db.getAllEpubBooks())
      .firstWhere((EpubBookRow b) => b.bookKey == bookKey);
}

Future<SyncBookResult> _exportBook(
  FushiDatabase db,
  SyncBackend backend,
  EpubBookRow book,
) async {
  await db.upsertReaderPosition(ReaderPositionsCompanion(
    bookUid: Value(book.uid),
    sectionIndex: const Value(0),
    normCharOffset: const Value(0),
    updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
  ));
  return SyncManager(db: db, backend: backend).syncBook(
    book: book,
    direction: SyncDirection.exportToTtu,
    syncStats: false,
    statsSyncMode: StatisticsSyncMode.merge,
    syncAudioBook: false,
    syncContent: true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory booksRoot;
  setUp(() {
    // importFromMangaJson 落盘到 <books root>/<bookKey>/——钉到临时根。
    booksRoot = Directory.systemTemp.createTempSync('hbk_cloud_manga_root');
    EpubStorage.debugBaseDirectoryOverride = booksRoot.path;
  });
  tearDown(() {
    EpubStorage.debugBaseDirectoryOverride = null;
    try {
      if (booksRoot.existsSync()) booksRoot.deleteSync(recursive: true);
    } catch (_) {
      // best-effort 清理（Windows 上偶有句柄未释放）。
    }
  });

  test('云盘 push：漫画书上传的是漫画包，不再被 EPUB 重打包静默吞掉', () async {
    final Directory src = _mangaBookDir(pages: 3);
    addTearDown(() => src.deleteSync(recursive: true));
    final FushiDatabase db = _memDb();
    addTearDown(db.close);

    final EpubBookRow book = await _insertBook(db,
        title: 'ワンピース 01', extractDir: src.path, format: BookFormat.manga);
    final _RecordingBackend backend = _RecordingBackend();

    final SyncBookResult result = await _exportBook(db, backend, book);
    expect(result.direction, SyncResult.exported);

    // 修复前：repackageExtractedEpub 对漫画目录恒 false → uploads 为空。
    expect(backend.uploads, hasLength(1), reason: '漫画必须真的上传（此前在所有云盘后端静默永不上传）');
    expect(backend.uploads.single.fileName, 'ワンピース 01.epub',
        reason: '与互联通道同契约：漫画包共用 `<title>.epub` 资产名');

    final File uploaded = File(p.join(src.parent.path, 'uploaded_probe.zip'))
      ..writeAsBytesSync(backend.uploads.single.bytes);
    addTearDown(() => uploaded.deleteSync());
    expect(await isMangaPackage(uploaded), isTrue,
        reason: '上传的字节必须是漫画包（zip 根含 manga.json），不是 EPUB 重打包');
  });

  test('云盘 push：PDF 无内容通道，既不上传也不产生半成品', () async {
    final Directory src = Directory.systemTemp.createTempSync('hbk_cloud_pdf');
    addTearDown(() => src.deleteSync(recursive: true));
    File(p.join(src.path, 'book.pdf')).writeAsBytesSync(<int>[0x25, 0x50]);
    final FushiDatabase db = _memDb();
    addTearDown(db.close);

    final EpubBookRow book = await _insertBook(db,
        title: 'Some PDF', extractDir: src.path, format: BookFormat.pdf);
    final _RecordingBackend backend = _RecordingBackend();

    await _exportBook(db, backend, book);
    expect(backend.uploads, isEmpty);
  });

  test('云盘 pull：`<title>.epub` 里装的是漫画包时，按内容落库成 format=manga', () async {
    final Directory src = _mangaBookDir(pages: 3);
    addTearDown(() => src.deleteSync(recursive: true));
    final Directory out = Directory.systemTemp.createTempSync('hbk_cloud_pull');
    addTearDown(() => out.deleteSync(recursive: true));
    final String zipPath = p.join(out.path, 'pkg.epub');
    expect(await repackageMangaBook(src.path, zipPath), isTrue);

    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final _FolderBackend backend =
        _FolderBackend(folderId: 'f1', assetName: 'ワンピース 01.epub')
          ..assetBytes = File(zipPath).readAsBytesSync();

    final bool imported = await importRemoteBookFolder(
      db: db,
      backend: backend,
      folderId: 'f1',
      tempDir: Directory(p.join(out.path, 'tmp')),
    );
    expect(imported, isTrue, reason: '修复前恒走 EpubImporter → 抛错，导不回来');

    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(1));
    expect(rows.single.format, BookFormat.manga.dbValue,
        reason: '漫画身份必须落地，而不是变成一本夹带页图的「文字书」');
    // 身份取远端资产名去扩展名，不含临时文件的时间戳（否则每次下载漂成新书）。
    expect(rows.single.bookKey, sanitizeTtuFilename('ワンピース 01'));
    expect(
        File(p.join(rows.single.extractDir, kMangaPackageMarker)).existsSync(),
        isTrue,
        reason: '页图与 manga.json 必须真的落盘');
  });

  test('云盘 pull：同名 `.epub` 里装的是真 EPUB 时仍走 EPUB 导入（无回归）', () async {
    final Archive archive = Archive();
    void add(String name, String content) {
      final List<int> bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('mimetype', 'application/epub+zip');
    add(
        'META-INF/container.xml',
        '<?xml version="1.0"?><container version="1.0" '
            'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="OEBPS/content.opf" '
            'media-type="application/oebps-package+xml"/></rootfiles>'
            '</container>');
    add(
        'OEBPS/content.opf',
        '<?xml version="1.0"?>'
            '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:title>Plain Book</dc:title></metadata>'
            '<manifest><item id="c" href="chapter.xhtml" '
            'media-type="application/xhtml+xml"/></manifest>'
            '<spine><itemref idref="c"/></spine></package>');
    add(
        'OEBPS/chapter.xhtml',
        '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml">'
            '<head><title>C</title></head><body><p>Hello.</p></body></html>');

    final Directory out = Directory.systemTemp.createTempSync('hbk_cloud_epub');
    addTearDown(() => out.deleteSync(recursive: true));

    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final _FolderBackend backend =
        _FolderBackend(folderId: 'f1', assetName: 'Plain Book.epub')
          ..assetBytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

    expect(
      await importRemoteBookFolder(
        db: db,
        backend: backend,
        folderId: 'f1',
        tempDir: Directory(p.join(out.path, 'tmp')),
      ),
      isTrue,
    );
    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(1));
    expect(rows.single.format, BookFormat.epub.dbValue);
  });
}
