import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

// ── 辅助 ──────────────────────────────────────────────────────────────────

/// 在 [db] 里插入一本书，同时在 [extractDir] 写入最小 EPUB 结构（让
/// repackageExtractedEpub 能成功打包）。
///
/// 最小 EPUB 需要 `mimetype` 文件（EPUB 规范要求）位于 extractDir 根。
Future<String> _insertBookWithExtractDir({
  required HibikiDatabase db,
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
  required HibikiDatabase db,
  List<File>? importedFiles,
  List<EpubBookRow>? deletedRows,
}) {
  return AppModelLibraryHostService(
    db: db,
    dictionaryResourceRoot: Directory.systemTemp,
    packages: SyncAssetPackageService(db: db),
    refreshDictionaryCache: () async {},
    runExclusive: (Future<void> Function() body) => body(),
    importBookFromFile:
        importedFiles == null ? null : (File f) async => importedFiles.add(f),
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
    late HibikiDatabase db;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hibiki_books_host');
      db = HibikiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
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
      // 给 AudioBook 这本书注册一条 Audiobooks 行（与本地书卡 hasAudiobook 同源：
      // bookKey 出现在 getAllAudiobooks）。
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

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteBookInfo> list = await svc.listBooks();
      final Map<String, RemoteBookInfo> byTitle = <String, RemoteBookInfo>{
        for (final RemoteBookInfo b in list) b.title: b,
      };

      expect(byTitle['AudioBook']!.hasAudiobook, isTrue);
      expect(byTitle['PlainBook']!.hasAudiobook, isFalse);
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
