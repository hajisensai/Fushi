import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/sync/manga_sync_package.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/cloud_book_content_names.dart';
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
// 命名（所有者 2026-10-21：书籍和漫画分开）：漫画包上传成 `<title>.manga.zip`，EPUB
// 仍是 `<title>.epub`；旧版本把漫画包也传成 `<title>.epub`，下载端新旧名都认，远端
// 已有旧名就不再传新名。导入侧一律按**内容**（zip 根 manga.json）嗅探分流。
// 「上传书籍文件」与「上传漫画文件」两个开关互不牵连，各管各的格式。

/// 造一个最小的已解压 EPUB 目录（repackageExtractedEpub 只认根有
/// `META-INF/container.xml`）。
Directory _epubBookDir() {
  final Directory dir = Directory.systemTemp.createTempSync('hbk_cloud_epub');
  Directory(p.join(dir.path, 'META-INF')).createSync();
  File(p.join(dir.path, 'mimetype')).writeAsStringSync('application/epub+zip');
  File(p.join(dir.path, 'META-INF', 'container.xml')).writeAsStringSync(
    '<?xml version="1.0"?><container version="1.0" '
    'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>',
  );
  return dir;
}

/// 造一个真实漫画书目录（根含 manga.json + 页图），即磁盘上的漫画布局。
Directory _mangaBookDir({int pages = 2}) {
  final Directory dir = Directory.systemTemp.createTempSync('hbk_cloud_manga');
  final Directory images = Directory(p.join(dir.path, 'images'))..createSync();
  final List<Map<String, Object?>> pageJson = <Map<String, Object?>>[];
  for (int i = 1; i <= pages; i++) {
    File(
      p.join(images.path, 'p$i.jpg'),
    ).writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, i]);
    pageJson.add(<String, Object?>{
      'url': 'images/p$i.jpg',
      'width': 800,
      'height': 1200,
      'blocks': <Object?>[],
    });
  }
  File(
    p.join(dir.path, kMangaPackageMarker),
  ).writeAsStringSync(jsonEncode(<String, Object?>{'pages': pageJson}));
  return dir;
}

/// 记录云盘 push 侧真正上传了什么（内容字节在回调里立刻读走——上传方在 finally
/// 里删临时目录，晚读必然拿不到）。
class _RecordingBackend implements SyncBackend {
  _RecordingBackend({
    this.listedNames = const <String>{},
    this.probedNames = const <String>{},
  });

  static const String root = 'ROOT/';

  /// 书文件夹列举（listChildren）里已有的文件名。
  final Set<String> listedNames;

  /// 只有逐个探针（findContentFile）才看得见的已有文件名（模拟列举快照陈旧）。
  final Set<String> probedNames;

  /// 写过的 sidecar：(folderId, 资产名)。
  final List<({String folderId, String name})> jsonAssets =
      <({String folderId, String name})>[];

  int listChildrenCalls = 0;

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
  }) async => '$rootFolderId${sanitizeTtuFilename(bookTitle)}/';

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async =>
      const SyncFileTrio();

  @override
  Future<SyncFileRef?> findContentFile(
    String folderId,
    String fileName,
  ) async => probedNames.contains(fileName) || listedNames.contains(fileName)
      ? SyncFileRef(id: '$folderId$fileName', name: fileName)
      : null;

  /// 补缺路径没有快照时列一次书文件夹。
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    listChildrenCalls++;
    return <AssetEntry>[
      for (final String name in listedNames)
        AssetEntry(id: '$namespaceId$name', name: name),
    ];
  }

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
    String namespaceId,
    String name,
    Object? json,
  ) async {
    jsonAssets.add((folderId: namespaceId, name: name));
  }

  // ── Cache ───────────────────────────────────────────────────────────
  @override
  void clearCache() {}
  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {}
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
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'unexpected backend call: '
    '${invocation.memberName}',
  );
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
  Future<void> getAsset(
    String id,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await destination.writeAsBytes(assetBytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'unexpected backend call: '
    '${invocation.memberName}',
  );
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
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: title,
      epubPath: 'book.epub',
      extractDir: extractDir,
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
      format: Value(format.dbValue),
    ),
  );
  return (await db.getAllEpubBooks()).firstWhere(
    (EpubBookRow b) => b.bookKey == bookKey,
  );
}

Future<SyncBookResult> _exportBook(
  FushiDatabase db,
  SyncBackend backend,
  EpubBookRow book, {
  bool syncContent = true,
  bool syncMangaContent = true,
}) async {
  await db.upsertReaderPosition(
    ReaderPositionsCompanion(
      bookUid: Value(book.uid),
      sectionIndex: const Value(0),
      normCharOffset: const Value(0),
      updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
    ),
  );
  return SyncManager(db: db, backend: backend).syncBook(
    book: book,
    direction: SyncDirection.exportToTtu,
    syncStats: false,
    statsSyncMode: StatisticsSyncMode.merge,
    syncAudioBook: false,
    syncContent: syncContent,
    syncMangaContent: syncMangaContent,
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

    final EpubBookRow book = await _insertBook(
      db,
      title: 'ワンピース 01',
      extractDir: src.path,
      format: BookFormat.manga,
    );
    final _RecordingBackend backend = _RecordingBackend();

    final SyncBookResult result = await _exportBook(db, backend, book);
    expect(result.direction, SyncResult.exported);

    // 修复前：repackageExtractedEpub 对漫画目录恒 false → uploads 为空。
    expect(backend.uploads, hasLength(1), reason: '漫画必须真的上传（此前在所有云盘后端静默永不上传）');
    expect(
      backend.uploads.single.fileName,
      'ワンピース 01.manga.zip',
      reason: '漫画包用漫画专属名 `<title>.manga.zip`，不再与 EPUB 共用 `.epub`',
    );

    final File uploaded = File(p.join(src.parent.path, 'uploaded_probe.zip'))
      ..writeAsBytesSync(backend.uploads.single.bytes);
    addTearDown(() => uploaded.deleteSync());
    expect(
      await isMangaPackage(uploaded),
      isTrue,
      reason: '上传的字节必须是漫画包（zip 根含 manga.json），不是 EPUB 重打包',
    );
  });

  test('云盘 push：PDF 无内容通道，既不上传也不产生半成品', () async {
    final Directory src = Directory.systemTemp.createTempSync('hbk_cloud_pdf');
    addTearDown(() => src.deleteSync(recursive: true));
    File(p.join(src.path, 'book.pdf')).writeAsBytesSync(<int>[0x25, 0x50]);
    final FushiDatabase db = _memDb();
    addTearDown(db.close);

    final EpubBookRow book = await _insertBook(
      db,
      title: 'Some PDF',
      extractDir: src.path,
      format: BookFormat.pdf,
    );
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
    final _FolderBackend backend = _FolderBackend(
      folderId: 'f1',
      assetName: 'ワンピース 01.epub',
    )..assetBytes = File(zipPath).readAsBytesSync();

    final bool imported = await importRemoteBookFolder(
      db: db,
      backend: backend,
      folderId: 'f1',
      tempDir: Directory(p.join(out.path, 'tmp')),
    );
    expect(imported, isTrue, reason: '修复前恒走 EpubImporter → 抛错，导不回来');

    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(1));
    expect(
      rows.single.format,
      BookFormat.manga.dbValue,
      reason: '漫画身份必须落地，而不是变成一本夹带页图的「文字书」',
    );
    // 身份取远端资产名去扩展名，不含临时文件的时间戳（否则每次下载漂成新书）。
    expect(rows.single.bookKey, sanitizeTtuFilename('ワンピース 01'));
    expect(
      File(p.join(rows.single.extractDir, kMangaPackageMarker)).existsSync(),
      isTrue,
      reason: '页图与 manga.json 必须真的落盘',
    );
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
          '</container>',
    );
    add(
      'OEBPS/content.opf',
      '<?xml version="1.0"?>'
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>Plain Book</dc:title></metadata>'
          '<manifest><item id="c" href="chapter.xhtml" '
          'media-type="application/xhtml+xml"/></manifest>'
          '<spine><itemref idref="c"/></spine></package>',
    );
    add(
      'OEBPS/chapter.xhtml',
      '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml">'
          '<head><title>C</title></head><body><p>Hello.</p></body></html>',
    );

    final Directory out = Directory.systemTemp.createTempSync('hbk_cloud_epub');
    addTearDown(() => out.deleteSync(recursive: true));

    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final _FolderBackend backend = _FolderBackend(
      folderId: 'f1',
      assetName: 'Plain Book.epub',
    )..assetBytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

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

  test('云盘 pull：新名 `<title>.manga.zip` 的漫画包导入，书名去掉双段后缀', () async {
    final Directory src = _mangaBookDir(pages: 2);
    addTearDown(() => src.deleteSync(recursive: true));
    final Directory out = Directory.systemTemp.createTempSync(
      'hbk_cloud_pull2',
    );
    addTearDown(() => out.deleteSync(recursive: true));
    final String zipPath = p.join(out.path, 'pkg.zip');
    expect(await repackageMangaBook(src.path, zipPath), isTrue);

    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final _FolderBackend backend = _FolderBackend(
      folderId: 'f1',
      assetName: 'ワンピース 02.manga.zip',
    )..assetBytes = File(zipPath).readAsBytesSync();

    expect(
      await importRemoteBookFolder(
        db: db,
        backend: backend,
        folderId: 'f1',
        tempDir: Directory(p.join(out.path, 'tmp')),
      ),
      isTrue,
      reason: '新名 `.manga.zip` 必须被认成书内容资产',
    );
    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(1));
    expect(rows.single.format, BookFormat.manga.dbValue);
    // basenameWithoutExtension 只去一层会留下 `ワンピース 02.manga`，书键漂移。
    expect(rows.single.bookKey, sanitizeTtuFilename('ワンピース 02'));
    expect(rows.single.title, 'ワンピース 02');
  });

  test('云盘 push：远端已有旧名 `<title>.epub` 漫画包（列举可见）时不再传新名', () async {
    final Directory src = _mangaBookDir();
    addTearDown(() => src.deleteSync(recursive: true));
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertBook(
      db,
      title: 'ワンピース 01',
      extractDir: src.path,
      format: BookFormat.manga,
    );
    final _RecordingBackend backend = _RecordingBackend(
      listedNames: <String>{'ワンピース 01.epub'},
    );

    await _exportBook(db, backend, book);
    expect(backend.uploads, isEmpty, reason: '旧版本传过的漫画包就是这本书的内容，不能再传第二份');
  });

  test('云盘 push：旧名只在探针里可见（列举快照陈旧）时同样不传', () async {
    final Directory src = _mangaBookDir();
    addTearDown(() => src.deleteSync(recursive: true));
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertBook(
      db,
      title: 'ワンピース 01',
      extractDir: src.path,
      format: BookFormat.manga,
    );
    final _RecordingBackend backend = _RecordingBackend(
      probedNames: <String>{'ワンピース 01.epub'},
    );

    await _exportBook(db, backend, book);
    expect(backend.uploads, isEmpty);
  });

  test('云盘 push：远端已有新名 `.manga.zip` 时不重传', () async {
    final Directory src = _mangaBookDir();
    addTearDown(() => src.deleteSync(recursive: true));
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final EpubBookRow book = await _insertBook(
      db,
      title: 'ワンピース 01',
      extractDir: src.path,
      format: BookFormat.manga,
    );
    final _RecordingBackend backend = _RecordingBackend(
      listedNames: <String>{'ワンピース 01.manga.zip'},
    );

    await _exportBook(db, backend, book);
    expect(backend.uploads, isEmpty);
  });

  group('「上传书籍文件」与「上传漫画文件」互不牵连', () {
    late Directory mangaSrc;
    late Directory epubSrc;
    late FushiDatabase db;
    late EpubBookRow manga;
    late EpubBookRow epub;

    setUp(() async {
      mangaSrc = _mangaBookDir();
      epubSrc = _epubBookDir();
      db = _memDb();
      manga = await _insertBook(
        db,
        title: 'Manga A',
        extractDir: mangaSrc.path,
        format: BookFormat.manga,
      );
      epub = await _insertBook(
        db,
        title: 'Novel B',
        extractDir: epubSrc.path,
        format: BookFormat.epub,
      );
      // 每本书一条自定义 CSS：sidecar 是否写出就能观测到「这本书的内容开关」。
      final int now = DateTime.now().millisecondsSinceEpoch;
      await db.upsertBookCss(manga.uid, 'style.css', 'p{}', now);
      await db.upsertBookCss(epub.uid, 'style.css', 'p{}', now);
    });
    tearDown(() async {
      await db.close();
      mangaSrc.deleteSync(recursive: true);
      epubSrc.deleteSync(recursive: true);
    });

    Set<String> cssFolders(_RecordingBackend backend) => <String>{
      for (final ({String folderId, String name}) a in backend.jsonAssets)
        if (a.name == kSyncBookCssAssetName) a.folderId,
    };

    test('书籍开、漫画关：EPUB 上传，漫画的书文件与 sidecar 都不碰', () async {
      final _RecordingBackend backend = _RecordingBackend();
      await _exportBook(
        db,
        backend,
        epub,
        syncContent: true,
        syncMangaContent: false,
      );
      await _exportBook(
        db,
        backend,
        manga,
        syncContent: true,
        syncMangaContent: false,
      );

      expect(backend.uploads.map((u) => u.fileName), <String>[
        cloudEpubContentFileName('Novel B'),
      ]);
      expect(cssFolders(backend), <String>{
        '${_RecordingBackend.root}Novel B/',
      });
    });

    test('书籍关、漫画开：漫画上传，EPUB 的书文件与 sidecar 都不碰', () async {
      final _RecordingBackend backend = _RecordingBackend();
      await _exportBook(
        db,
        backend,
        epub,
        syncContent: false,
        syncMangaContent: true,
      );
      await _exportBook(
        db,
        backend,
        manga,
        syncContent: false,
        syncMangaContent: true,
      );

      expect(backend.uploads.map((u) => u.fileName), <String>[
        cloudMangaContentFileName('Manga A'),
      ]);
      expect(cssFolders(backend), <String>{
        '${_RecordingBackend.root}Manga A/',
      });
    });

    test('syncAllBooks 把两个开关原样传到每本书', () async {
      final _RecordingBackend backend = _RecordingBackend();
      await SyncManager(db: db, backend: backend).syncAllBooks(
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
        syncContent: false,
        syncMangaContent: true,
      );
      expect(backend.uploads.map((u) => u.fileName), <String>[
        cloudMangaContentFileName('Manga A'),
      ]);
    });
  });

  group('书内容资产命名判据', () {
    test('isRemoteBookContentName 认 .epub 与 .manga.zip（大小写不敏感）', () {
      expect(isRemoteBookContentName('a.epub'), isTrue);
      expect(isRemoteBookContentName('a.EPUB'), isTrue);
      expect(isRemoteBookContentName('a.manga.zip'), isTrue);
      expect(isRemoteBookContentName('a.MANGA.ZIP'), isTrue);
      expect(isRemoteBookContentName('a.zip'), isFalse);
      expect(isRemoteBookContentName('book_css.json'), isFalse);
      expect(isRemoteBookContentName('audiobook.fushiaudio'), isFalse);
    });

    test('两种并存时优先新名', () {
      expect(
        pickRemoteBookContentEntry<String>(<String>[
          'x.epub',
          'cover.jpg',
          'x.manga.zip',
        ], (String n) => n),
        'x.manga.zip',
      );
      expect(
        pickRemoteBookContentEntry<String>(<String>[
          'cover.jpg',
          'x.epub',
        ], (String n) => n),
        'x.epub',
      );
      expect(
        pickRemoteBookContentEntry<String>(<String>[
          'cover.jpg',
        ], (String n) => n),
        isNull,
      );
    });

    test('remoteBookContentBaseName 去掉整个内容后缀', () {
      expect(remoteBookContentBaseName('t.manga.zip'), 't');
      expect(remoteBookContentBaseName('t.epub'), 't');
      expect(remoteBookContentBaseName('t.zip'), 't.zip');
    });
  });
}
