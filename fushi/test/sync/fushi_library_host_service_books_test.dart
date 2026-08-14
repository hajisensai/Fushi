import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/sync/app_model_library_host_service.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/manga_sync_package.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

// ── 辅助 ──────────────────────────────────────────────────────────────────

/// 在 [db] 里插入一本书，同时在 [extractDir] 写入最小 EPUB 结构（让
/// repackageExtractedEpub 能成功打包）。
///
/// 最小 EPUB 需要 `mimetype` 文件（EPUB 规范要求）位于 extractDir 根。
Future<String> _insertBookWithExtractDir({
  required FushiDatabase db,
  required String title,
  required String extractDir,
  String? bookKey,
}) async {
  Directory(extractDir).createSync(recursive: true);
  // 写入 mimetype（repackageExtractedEpub 靠它识别 EPUB 格式）
  File(p.join(extractDir, 'mimetype'))
      .writeAsStringSync('application/epub+zip');
  // 写入最小 content.opf（让产出的 zip 非空且可识别）
  final Directory metaInf = Directory(p.join(extractDir, 'META-INF'))
    ..createSync();
  File(p.join(metaInf.path, 'container.xml')).writeAsStringSync(
    '<?xml version="1.0"?>'
    '<container version="1.0" xmlns="urn:oasis:schemas:container">'
    '<rootfiles><rootfile full-path="content.opf"'
    ' media-type="application/oebps-package+xml"/></rootfiles>'
    '</container>',
  );
  File(p.join(extractDir, 'content.opf')).writeAsStringSync(
    '<?xml version="1.0"?>'
    '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
    '<metadata/><manifest/><spine/></package>',
  );

  return db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey ?? title,
      title: title,
      epubPath: p.join(extractDir, 'original.epub'),
      extractDir: extractDir,
      chapterCount: 1,
      chaptersJson: '["ch1"]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

/// 构造一个 [AppModelLibraryHostService]，[importBookFromFile] 为 fake（记录调用）。
AppModelLibraryHostService _buildSvc({
  required FushiDatabase db,
  List<File>? importedFiles,
  List<EpubBookRow>? deletedRows,
}) {
  return AppModelLibraryHostService(
    db: db,
    dictionaryResourceRoot: Directory.systemTemp,
    packages: SyncAssetPackageService(db: db),
    refreshDictionaryCache: () async {},
    runExclusive: (Future<void> Function() body) => body(),
    importBookFromFile: importedFiles == null
        ? null
        : (File f) async {
            importedFiles.add(f);
            return null;
          },
    cleanupBookOnDisk: deletedRows == null
        ? null
        : (EpubBookRow row) async => deletedRows.add(row),
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  // ── computeBookSyncDiff 纯函数 ──────────────────────────────────────────
  group('computeBookSyncDiff', () {
    test('远端有内容∧本端无 → toPull；本端有∧远端无 → toPush；共有 → 都不动', () {
      final BookSyncDiff diff = computeBookSyncDiff(
        localKeys: <String>{'BookA', 'BookB'},
        remoteKeyHasContent: <String, bool>{
          'BookB': true,
          'BookC': true, // 远端有内容，本端无 → toPull
        },
      );
      expect(diff.toPull, <String>{'BookC'});
      expect(diff.toPush, <String>{'BookA'});
    });

    test('远端书 hasContent==false 不进 toPull', () {
      final BookSyncDiff diff = computeBookSyncDiff(
        localKeys: <String>{},
        remoteKeyHasContent: <String, bool>{
          'EmptyBook': false,
          'RealBook': true,
        },
      );
      expect(diff.toPull, <String>{'RealBook'});
      expect(diff.toPull, isNot(contains('EmptyBook')));
    });

    test('两端均空 → 空 diff', () {
      final BookSyncDiff diff = computeBookSyncDiff(
        localKeys: <String>{},
        remoteKeyHasContent: <String, bool>{},
      );
      expect(diff.toPull, isEmpty);
      expect(diff.toPush, isEmpty);
    });

    test('本端全在远端 → toPush 为空', () {
      final BookSyncDiff diff = computeBookSyncDiff(
        localKeys: <String>{'X', 'Y'},
        remoteKeyHasContent: <String, bool>{'X': true, 'Y': true, 'Z': true},
      );
      expect(diff.toPush, isEmpty);
      expect(diff.toPull, <String>{'Z'});
    });
  });

  // ── RemoteBookInfo JSON round-trip ──────────────────────────────────────
  group('RemoteBookInfo', () {
    test('toJson / fromJson round-trip', () {
      const RemoteBookInfo info =
          RemoteBookInfo(title: '夏目漱石', hasContent: true);
      final RemoteBookInfo decoded = RemoteBookInfo.fromJson(info.toJson());
      expect(decoded.title, info.title);
      expect(decoded.hasContent, info.hasContent);
    });

    test('bookKey survives JSON round-trip for download identity', () {
      final RemoteBookInfo info = RemoteBookInfo.fromJson(<String, Object?>{
        'title': r'Vol 1/2\3?..: Finale',
        'bookKey': 'Vol_1_2_3_Finale',
        'hasContent': true,
      });

      expect(info.toJson()['bookKey'], 'Vol_1_2_3_Finale');
    });

    test('fromJson 缺字段降级为安全默认值', () {
      final RemoteBookInfo info = RemoteBookInfo.fromJson(<String, Object?>{});
      expect(info.title, '');
      expect(info.hasContent, isFalse);
      expect(info.hasAudiobook, isFalse);
    });

    test('hasAudiobook 经 JSON round-trip 透传（TODO-655a）', () {
      const RemoteBookInfo info = RemoteBookInfo(
        title: '夏目漱石',
        hasContent: true,
        hasAudiobook: true,
      );
      final RemoteBookInfo decoded = RemoteBookInfo.fromJson(info.toJson());
      expect(decoded.hasAudiobook, isTrue);

      const RemoteBookInfo plain =
          RemoteBookInfo(title: 'NoAudio', hasContent: true);
      expect(plain.toJson()['hasAudiobook'], isNot(true));
      expect(RemoteBookInfo.fromJson(plain.toJson()).hasAudiobook, isFalse);
    });
  });

  // ── AppModelLibraryHostService 书籍 round-trip ─────────────────────────
  group('AppModelLibraryHostService books', () {
    late Directory tmp;
    late FushiDatabase db;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hibiki_books_host');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    // ── 漫画互联（互联完整支持批次）────────────────────────────────────────
    Future<String> insertMangaBook({
      required String title,
      required String extractDir,
      bool withEpubTree = false,
      String? mangaReadingMode,
    }) async {
      Directory(extractDir).createSync(recursive: true);
      final Directory images = Directory(p.join(extractDir, 'images'))
        ..createSync();
      File(p.join(images.path, 'p1.jpg'))
          .writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, 1]);
      File(p.join(extractDir, 'manga.json')).writeAsStringSync(jsonEncode(
        <String, Object?>{
          'pages': <Object?>[
            <String, Object?>{
              'url': 'images/p1.jpg',
              'width': 800,
              'height': 1200,
              'blocks': <Object?>[],
            },
          ],
        },
      ));
      if (withEpubTree) {
        // 由 EPUB 转化来的漫画：书目录里仍留着 EPUB 解压树。
        final Directory metaInf = Directory(p.join(extractDir, 'META-INF'))
          ..createSync();
        File(p.join(metaInf.path, 'container.xml')).writeAsStringSync('<xml/>');
      }
      return db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: title,
        title: title,
        epubPath: 'manga.json',
        extractDir: extractDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: Value(BookFormat.manga.dbValue),
        coverPath: const Value('images/p1.jpg'),
        mangaReadingMode: Value(mangaReadingMode),
      ));
    }

    test('listBooks 漫画行：format/hasMangaContent 下发、hasContent 恒 false',
        () async {
      await insertMangaBook(
        title: 'MangaVol1',
        extractDir: p.join(tmp.path, 'MangaVol1'),
        mangaReadingMode: 'webtoon',
      );
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final RemoteBookInfo info = (await svc.listBooks()).single;
      expect(info.format, 'manga');
      expect(info.hasMangaContent, isTrue, reason: '新 client 据此在漫画架渲染可下载占位卡');
      expect(info.hasContent, isFalse,
          reason: '旧 client 只认 hasContent——漫画对它必须完全无感知');
      expect(info.mangaReadingMode, 'webtoon');
      // wire 往返（additive 字段向后兼容）。
      final RemoteBookInfo back = RemoteBookInfo.fromJson(info.toJson());
      expect(back.format, 'manga');
      expect(back.hasMangaContent, isTrue);
      expect(back.mangaReadingMode, 'webtoon');
      final RemoteBookInfo legacy = RemoteBookInfo.fromJson(
          <String, Object?>{'title': 'x', 'hasContent': true});
      expect(legacy.format, 'epub');
      expect(legacy.hasMangaContent, isFalse);
    });

    test('EPUB 转化漫画（extractDir 残留 container.xml）hasContent 必须 false（坏包防线）',
        () async {
      await insertMangaBook(
        title: 'ConvertedManga',
        extractDir: p.join(tmp.path, 'ConvertedManga'),
        withEpubTree: true,
      );
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final RemoteBookInfo info = (await svc.listBooks()).single;
      expect(info.hasContent, isFalse,
          reason: '旧判据会把它当可下载 EPUB 打包——client 落地成夹带整套页图的'
              '文字书、漫画身份静默丢失');
      expect(info.hasMangaContent, isTrue);
    });

    test('exportBook 漫画 → 整树 zip（isMangaPackage 嗅中）；再 import 落库保真', () async {
      await insertMangaBook(
        title: 'ExportManga',
        extractDir: p.join(tmp.path, 'ExportManga'),
      );
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final File pkg = await svc.exportBook('ExportManga');
      addTearDown(() => pkg.parent.deleteSync(recursive: true));
      expect(await isMangaPackage(pkg), isTrue,
          reason: '导入侧（host importBook / client 下载）按内容嗅探分流');

      // 端到端：包导入到另一个库，漫画身份/页图/封面保真。落库根钉到临时目录
      // （importFromMangaJson 经 EpubStorage 解析书目录根）。
      final Directory booksRoot =
          Directory.systemTemp.createTempSync('hbk_books_import_root');
      EpubStorage.debugBaseDirectoryOverride = booksRoot.path;
      addTearDown(() {
        EpubStorage.debugBaseDirectoryOverride = null;
        if (booksRoot.existsSync()) booksRoot.deleteSync(recursive: true);
      });
      final FushiDatabase db2 =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db2.close);
      final String key = await importMangaPackageFile(
          db: db2, file: pkg, title: 'ExportManga');
      final EpubBookRow? row = await db2.getEpubBook(key);
      expect(row!.format, 'manga');
      expect(File(p.join(row.extractDir, 'images', 'p1.jpg')).existsSync(),
          isTrue);
    });

    // ── listBooks ──────────────────────────────────────────────────────────
    test('listBooks 反映 DB 书库，extractDir 存在时 hasContent==true', () async {
      final String extractDir = p.join(tmp.path, 'MyBook');
      await _insertBookWithExtractDir(
        db: db,
        title: 'MyBook',
        extractDir: extractDir,
      );

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteBookInfo> list = await svc.listBooks();

      expect(list, hasLength(1));
      expect(list.first.title, 'MyBook');
      expect(list.first.hasContent, isTrue);
    });

    test('listBooks 对有有声书的书填 hasAudiobook==true，无的填 false（TODO-655a）',
        () async {
      final String audioExtract = p.join(tmp.path, 'AudioBook');
      final String audioKey = await _insertBookWithExtractDir(
        db: db,
        title: 'AudioBook',
        extractDir: audioExtract,
      );
      final String plainExtract = p.join(tmp.path, 'PlainBook');
      await _insertBookWithExtractDir(
        db: db,
        title: 'PlainBook',
        extractDir: plainExtract,
      );
      // 给 AudioBook 这本书注册可经 live-sync 导出的有声书：Audiobooks + SrtBooks
      // 两表齐备（与 listAudiobooks / exportAudiobook 同源，TODO-778）。
      final Directory audioDir = Directory(p.join(tmp.path, 'audio'))
        ..createSync(recursive: true);
      final File track = File(p.join(audioDir.path, 'track.m4b'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final File align = File(p.join(audioDir.path, 'align.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhi\n');
      await db.upsertAudiobook(AudiobooksCompanion.insert(
        bookKey: audioKey,
        audioRoot: Value(audioDir.path),
        audioPathsJson: Value(jsonEncode(<String>[track.path])),
        alignmentFormat: 'srt',
        alignmentPath: align.path,
      ));
      await db.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srt-audiobook',
        title: 'AudioBook',
        audioRoot: Value(audioDir.path),
        audioPathsJson: Value(jsonEncode(<String>[track.path])),
        srtPath: align.path,
        importedAt: 0,
        bookKey: Value(audioKey),
      ));

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteBookInfo> list = await svc.listBooks();
      final Map<String, RemoteBookInfo> byTitle = <String, RemoteBookInfo>{
        for (final RemoteBookInfo b in list) b.title: b,
      };

      expect(byTitle['AudioBook']!.hasAudiobook, isTrue);
      expect(byTitle['PlainBook']!.hasAudiobook, isFalse);
    });

    test(
        'listBooks 对孤儿有声书（有 Audiobook 无 SrtBook）填 hasAudiobook==false（TODO-778）',
        () async {
      // EPUB 对齐有声书的形态：有 Audiobooks 行但没有 SrtBooks 行。
      // exportAudiobook 要求两表齐备，缺 SrtBook 即抛 StateError → 服务端 404；
      // 故 hasAudiobook 徽章必须排除它，否则 client 亮耳机却下载 404。
      final String orphanExtract = p.join(tmp.path, 'OrphanAudio');
      final String orphanKey = await _insertBookWithExtractDir(
        db: db,
        title: 'OrphanAudio',
        extractDir: orphanExtract,
      );
      final Directory audioDir = Directory(p.join(tmp.path, 'orphan-audio'))
        ..createSync(recursive: true);
      final File align = File(p.join(audioDir.path, 'align.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhi\n');
      await db.upsertAudiobook(AudiobooksCompanion.insert(
        bookKey: orphanKey,
        audioRoot: Value(audioDir.path),
        alignmentFormat: 'srt',
        alignmentPath: align.path,
      ));
      // 故意不插 SrtBooks 行。

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteBookInfo> list = await svc.listBooks();
      final RemoteBookInfo orphan =
          list.firstWhere((RemoteBookInfo b) => b.title == 'OrphanAudio');

      // 徽章判据修复后：孤儿有声书不亮 hasAudiobook。
      expect(orphan.hasAudiobook, isFalse);

      // 印证根因链：徽章亮起本会触发的 exportAudiobook 此时确实抛 StateError
      //（即服务端 404 的来源），证明排除它不误伤——被排除的本就 100% 下载失败。
      await expectLater(
        svc.exportAudiobook(orphanKey),
        throwsA(isA<StateError>()),
      );
    });

    test('#4 listBooks 把 EPUB 内部相对 href 封面解析成可服务的绝对路径', () async {
      // 这是真实 EPUB 书的封面存储形式：coverPath = EPUB 内相对 href，封面文件在
      // extractDir 里。修复前 host 直接 File(相对href).existsSync() 恒 false → 远端
      // 书卡没封面（#4），视频侧因 coverPath 是绝对路径而不受影响。
      final String extractDir = p.join(tmp.path, 'HrefBook');
      final String bookKey = await _insertBookWithExtractDir(
        db: db,
        title: 'HrefBook',
        extractDir: extractDir,
      );
      final String coverRel = p.join('OEBPS', 'images', 'cover.jpg');
      File(p.join(extractDir, coverRel))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      // DB 里存的是相对 href（与 EpubImporter 写入 coverHref 一致）。
      await db.updateEpubBookContentPaths(bookKey, coverPath: coverRel);

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteBookInfo> list = await svc.listBooks();

      // 解析后是磁盘存在的绝对路径，hasCover==true，server 据此能下发 coverUrl。
      expect(list.single.coverPath, p.join(extractDir, coverRel));
      expect(list.single.toJson()['hasCover'], isTrue);
    });

    test('listBooks 标记已有本地封面可供对端展示', () async {
      final String extractDir = p.join(tmp.path, 'CoveredBook');
      final String bookKey = await _insertBookWithExtractDir(
        db: db,
        title: 'CoveredBook',
        extractDir: extractDir,
      );
      final File cover = File(p.join(tmp.path, 'covered-book.png'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      await db.updateEpubBookContentPaths(bookKey, coverPath: cover.path);

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteBookInfo> list = await svc.listBooks();

      expect(list.single.toJson()['hasCover'], isTrue);
    });

    test('listBooks extractDir 不存在时 hasContent==false', () async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'Ghost',
          title: 'Ghost',
          epubPath: '/nonexistent/ghost.epub',
          extractDir: '/nonexistent/ghost',
          chapterCount: 0,
          chaptersJson: '[]',
          importedAt: 0,
        ),
      );

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteBookInfo> list = await svc.listBooks();

      expect(list.first.hasContent, isFalse);
    });

    // ── exportBook ─────────────────────────────────────────────────────────
    test('exportBook 产出非空 .epub 文件', () async {
      final String extractDir = p.join(tmp.path, 'ExportMe');
      await _insertBookWithExtractDir(
        db: db,
        title: 'ExportMe',
        extractDir: extractDir,
      );

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final File pkg = await svc.exportBook('ExportMe');
      addTearDown(() => pkg.parent.deleteSync(recursive: true));

      expect(pkg.existsSync(), isTrue);
      expect(pkg.lengthSync(), greaterThan(0));
      expect(pkg.path, endsWith('.epub'));
    });

    test('exportBook accepts stable bookKey for special display titles',
        () async {
      const String displayTitle = r'Vol 1/2\3?..: Finale';
      const String bookKey = 'Vol_1_2_3_Finale';
      final String extractDir = p.join(tmp.path, 'SpecialTitle');
      await _insertBookWithExtractDir(
        db: db,
        title: displayTitle,
        bookKey: bookKey,
        extractDir: extractDir,
      );

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final File pkg = await svc.exportBook(bookKey);
      addTearDown(() => pkg.parent.deleteSync(recursive: true));

      expect(pkg.existsSync(), isTrue);
      expect(pkg.lengthSync(), greaterThan(0));
    });

    test('exportBook 自动使用 extractDir 下的真实 EPUB 根目录', () async {
      final String outerDir = p.join(tmp.path, 'NestedExport');
      final String realEpubRoot = p.join(outerDir, 'EPUB_ROOT');
      await _insertBookWithExtractDir(
        db: db,
        title: 'NestedExport',
        extractDir: realEpubRoot,
      );
      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      await db.updateEpubBookContentPaths(
        row.bookKey,
        extractDir: outerDir,
      );

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteBookInfo> list = await svc.listBooks();

      expect(list.single.hasContent, isTrue);

      final File pkg = await svc.exportBook('NestedExport');
      addTearDown(() => pkg.parent.deleteSync(recursive: true));

      final Archive archive = ZipDecoder().decodeBytes(await pkg.readAsBytes());
      expect(archive.findFile('META-INF/container.xml'), isNotNull);
      expect(archive.findFile('EPUB_ROOT/META-INF/container.xml'), isNull);
    });

    test('exportBook 对不存在的书抛 StateError', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportBook('NonExistent'),
        throwsA(isA<StateError>()),
      );
    });

    test('exportBook 对 extractDir 不存在的书抛 StateError（无内容）', () async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'NoContent',
          title: 'NoContent',
          epubPath: '/nowhere/nc.epub',
          extractDir: '/nowhere/nc',
          chapterCount: 0,
          chaptersJson: '[]',
          importedAt: 0,
        ),
      );

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportBook('NoContent'),
        throwsA(isA<StateError>()),
      );
    });

    test('exportBook 对 "../evil" 路径穿越抛 ArgumentError', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportBook('../evil'),
        throwsA(isA<ArgumentError>()),
      );
    });

    // ── deleteBook ─────────────────────────────────────────────────────────
    test('deleteBook 后 listBooks 不含该书，extractDir 被删', () async {
      final String extractDir = p.join(tmp.path, 'DeleteMe');
      await _insertBookWithExtractDir(
        db: db,
        title: 'DeleteMe',
        extractDir: extractDir,
      );

      final List<EpubBookRow> deletedRows = <EpubBookRow>[];
      final AppModelLibraryHostService svc =
          _buildSvc(db: db, deletedRows: deletedRows);

      await svc.deleteBook('DeleteMe');

      final List<RemoteBookInfo> list = await svc.listBooks();
      expect(list, isEmpty);
      expect(Directory(extractDir).existsSync(), isFalse);
      // cleanupBookOnDisk 回调被调用且拿到了正确 row
      expect(deletedRows, hasLength(1));
      expect(deletedRows.first.title, 'DeleteMe');
    });

    test('deleteBook 不存在的书静默跳过（幂等）', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      // 不抛异常
      await svc.deleteBook('NonExistent');
    });

    test('deleteBook 对路径穿越名抛 ArgumentError', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.deleteBook('../evil'),
        throwsA(isA<ArgumentError>()),
      );
    });

    // ── importBook（fake importer 回调）─────────────────────────────────────
    test('importBook 调用注入的 importer 回调', () async {
      final List<File> imported = <File>[];
      final AppModelLibraryHostService svc =
          _buildSvc(db: db, importedFiles: imported);

      final File fakeEpub = File(p.join(tmp.path, 'fake.epub'))
        ..writeAsBytesSync(<int>[0, 1, 2]);

      await svc.importBook(fakeEpub);

      expect(imported, hasLength(1));
      expect(imported.first.path, fakeEpub.path);
    });

    test('importBook 无回调时抛 UnsupportedError', () async {
      final AppModelLibraryHostService svc = AppModelLibraryHostService(
        db: db,
        dictionaryResourceRoot: Directory.systemTemp,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        // importBookFromFile 未传 → null
      );

      final File fakeEpub = File(p.join(tmp.path, 'fake.epub'))
        ..writeAsBytesSync(<int>[0]);

      await expectLater(
        svc.importBook(fakeEpub),
        throwsA(isA<UnsupportedError>()),
      );
    });

    // ── round-trip：export → 验内容 → delete ──────────────────────────────
    test('export 产出可被重识别的 epub zip（包含 mimetype）', () async {
      final String extractDir = p.join(tmp.path, 'RoundTrip');
      await _insertBookWithExtractDir(
        db: db,
        title: 'RoundTrip',
        extractDir: extractDir,
      );

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final File pkg = await svc.exportBook('RoundTrip');
      addTearDown(() => pkg.parent.deleteSync(recursive: true));

      // epub 是 zip，magic bytes 为 PK\x03\x04
      final List<int> magic = pkg.readAsBytesSync().take(4).toList();
      expect(magic[0], 0x50); // 'P'
      expect(magic[1], 0x4B); // 'K'
      expect(magic[2], 0x03);
      expect(magic[3], 0x04);

      // delete 后清理
      await svc.deleteBook('RoundTrip');
      expect(await svc.listBooks(), isEmpty);
    });
  });
}
