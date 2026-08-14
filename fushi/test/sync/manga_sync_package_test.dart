import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/sync/manga_sync_package.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 互联漫画包（互联完整支持批次）：打包 / 嗅探 / 解压防穿越 / 端到端落库。
///
/// 包 = 漫画书目录整树 zip（根含 manga.json + 页图），与 EPUB 包同端点、内容
/// 嗅探分流——这里锁死「布局即真相」契约与安全边界。
Directory _mangaBookDir({int pages = 2}) {
  final Directory dir =
      Directory.systemTemp.createTempSync('hbk_manga_pkg_src');
  final Directory images = Directory(p.join(dir.path, 'images'))..createSync();
  final List<Map<String, Object?>> pageJson = <Map<String, Object?>>[];
  for (int i = 1; i <= pages; i++) {
    final File img = File(p.join(images.path, 'p$i.jpg'));
    img.writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, i]); // 假 JPEG 头 + 序号
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory booksRoot;
  setUp(() {
    // importFromMangaJson 落库到 <books root>/<bookKey>/——测试钉到临时根。
    booksRoot = Directory.systemTemp.createTempSync('hbk_pkg_books_root');
    EpubStorage.debugBaseDirectoryOverride = booksRoot.path;
  });
  tearDown(() {
    EpubStorage.debugBaseDirectoryOverride = null;
    if (booksRoot.existsSync()) booksRoot.deleteSync(recursive: true);
  });

  test('repackageMangaBook 打整树包；isMangaPackage 嗅中；extract 内容往返', () async {
    final Directory src = _mangaBookDir();
    addTearDown(() => src.deleteSync(recursive: true));
    final Directory out = Directory.systemTemp.createTempSync('hbk_pkg_out');
    addTearDown(() => out.deleteSync(recursive: true));
    final String zipPath = p.join(out.path, 'book.epub');

    expect(await repackageMangaBook(src.path, zipPath), isTrue);
    expect(await isMangaPackage(File(zipPath)), isTrue,
        reason: '嗅探必须命中根级 manga.json（books 端点按内容分流的唯一判据）');

    final Directory unpacked = await extractMangaPackage(File(zipPath));
    addTearDown(() => unpacked.deleteSync(recursive: true));
    expect(
        File(p.join(unpacked.path, kMangaPackageMarker)).existsSync(), isTrue);
    expect(File(p.join(unpacked.path, 'images', 'p1.jpg')).readAsBytesSync(),
        <int>[0xFF, 0xD8, 0xFF, 1],
        reason: '页图字节必须原样往返');
  });

  test('非漫画目录不打包；EPUB 样式 zip 嗅探不命中；坏文件不命中不抛', () async {
    final Directory notManga =
        Directory.systemTemp.createTempSync('hbk_not_manga');
    addTearDown(() => notManga.deleteSync(recursive: true));
    File(p.join(notManga.path, 'mimetype'))
        .writeAsStringSync('application/epub+zip');
    final String zipPath = p.join(notManga.path, 'out.zip');
    expect(await repackageMangaBook(notManga.path, zipPath), isFalse);
    expect(File(zipPath).existsSync(), isFalse, reason: 'false 时不得留半成品文件');

    // EPUB 样式 zip（有 META-INF/container.xml，无 manga.json）。
    final ZipFileEncoder enc = ZipFileEncoder()..create(zipPath);
    enc.addArchiveFile(
        ArchiveFile('META-INF/container.xml', 4, utf8.encode('<xml')));
    enc.close();
    expect(await isMangaPackage(File(zipPath)), isFalse);

    // 非 zip 文件：不抛、按非漫画处理。
    final File garbage = File(p.join(notManga.path, 'garbage.bin'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    expect(await isMangaPackage(garbage), isFalse);
  });

  test('extractMangaPackage 拒绝路径穿越条目（zip-slip 防线）', () async {
    final Directory out = Directory.systemTemp.createTempSync('hbk_evil');
    addTearDown(() => out.deleteSync(recursive: true));
    final String zipPath = p.join(out.path, 'evil.zip');
    final ZipFileEncoder enc = ZipFileEncoder()..create(zipPath);
    enc.addArchiveFile(ArchiveFile(kMangaPackageMarker, 2, utf8.encode('{}')));
    enc.addArchiveFile(ArchiveFile('../evil.txt', 4, utf8.encode('evil')));
    enc.close();

    await expectLater(
      extractMangaPackage(File(zipPath)),
      throwsA(isA<FormatException>()),
      reason: '含 .. 段的条目必须整体拒绝，绝不能写出临时目录之外',
    );
  });

  test('端到端：repackage → importMangaPackageFile 落库 format=manga + 页图落地',
      () async {
    final Directory src = _mangaBookDir(pages: 3);
    addTearDown(() => src.deleteSync(recursive: true));
    final Directory out = Directory.systemTemp.createTempSync('hbk_pkg_e2e');
    addTearDown(() => out.deleteSync(recursive: true));
    final String zipPath = p.join(out.path, 'ワンピース 01.epub');
    expect(await repackageMangaBook(src.path, zipPath), isTrue);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final String bookKey = await importMangaPackageFile(
      db: db,
      file: File(zipPath),
      title: 'ワンピース 01',
    );

    final EpubBookRow? row = await db.getEpubBook(bookKey);
    expect(row, isNotNull);
    expect(row!.format, BookFormat.manga.dbValue,
        reason: '漫画身份必须保真（不能落成 epub 丢 OCR 查词层）');
    expect(row.chapterCount, 3, reason: '漫画 chapterCount = 页数');
    expect(
        File(p.join(row.extractDir, kMangaPackageMarker)).existsSync(), isTrue);
    expect(
        File(p.join(row.extractDir, row.coverPath ?? '')).existsSync(), isTrue,
        reason: '封面 = 首页页图相对路径，必须能解析到磁盘文件');
  });
}
