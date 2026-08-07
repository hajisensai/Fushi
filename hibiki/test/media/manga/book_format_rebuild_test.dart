/// 「书 ↔ 漫画」转化的**产物重建 + 落库**端到端（真磁盘 + 真 SQLite）。
///
/// `book_format_convert_test.dart` 只覆盖纯判定，`epub_book_format_convert_test.dart`
/// 只覆盖单条 DAO。本文件把两端接起来跑真流程：解压树/PDF → 页图 + `manga.json`
/// → 单事务改行 → 再转回来。四条验收口径（身份逐字节不变、书架恰好一条、进度与
/// 最后阅读时刻不丢、跳回原文进正确阅读器）都在这里落地。
///
/// PDFium 是平台原生库、`flutter test` 里拉不起来，故 PDF 两处原生依赖走
/// [BookFormatRebuild.debugPdfPageStager] / [BookFormatRebuild.debugPdfPageCounter]
/// 注入——被测的是转化的**编排、产物布局与落库**，不是 PDFium 本身。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/manga/book_format_convert.dart';
import 'package:fushi/src/media/manga/book_format_rebuild.dart';
import 'package:fushi/src/media/manga/manga_storage.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String bookKey = 'Scanned Volume 01';
  late Directory root;
  late String bookDir;
  late HibikiDatabase db;

  setUp(() {
    root = Directory.systemTemp.createTempSync('book_convert_');
    bookDir = p.join(root.path, bookKey);
    Directory(bookDir).createSync(recursive: true);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    BookFormatRebuild.debugPdfPageStager = null;
    BookFormatRebuild.debugPdfPageCounter = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> seedRow({
    required BookFormat format,
    required String epubPath,
    required int chapterCount,
    required String chaptersJson,
    String? coverPath,
  }) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: epubPath,
        extractDir: bookDir,
        chapterCount: chapterCount,
        chaptersJson: chaptersJson,
        importedAt: 1700000000000,
        format: Value<String>(format.dbValue),
        coverPath:
            coverPath == null ? const Value.absent() : Value<String>(coverPath),
        author: const Value<String>('作者'),
      ),
    );
  }

  Future<EpubBookRow> row() async => (await db.getEpubBook(bookKey))!;

  // ── 图片型 EPUB → 漫画 ───────────────────────────────────────────────

  test('图片型 EPUB 转成漫画：页图 + manga.json 落进书目录，行一次写穿', () async {
    writeExtractedImageEpub(bookDir);
    await seedRow(
      format: BookFormat.epub,
      epubPath: 'scan.epub',
      chapterCount: 2,
      chaptersJson: '[{"id":"page1","characters":0}]',
      coverPath: 'OEBPS/images/1.png',
    );

    await BookFormatRebuild.convert(
      db: db,
      row: await row(),
      target: BookFormatTarget.manga,
    );

    // 磁盘产物：漫画阅读器硬要求 extractDir/manga.json + 同目录 images/。
    final File json = File(p.join(bookDir, MangaStorage.kMangaJsonFileName));
    expect(json.existsSync(), isTrue);
    final MokuroPayload payload = parseMangaJson(json.readAsStringSync());
    expect(payload.images, hasLength(2));
    for (final MokuroImage image in payload.images) {
      expect(MangaStorage.destFile(bookDir, image.url).existsSync(), isTrue);
    }
    // spine 顺序：fixture 的 spine 是 page2 → page1，故第一页是 30px 宽那张。
    expect(payload.images.first.size.width, 30);

    final EpubBookRow after = await row();
    expect(after.format, BookFormat.manga.dbValue);
    expect(after.epubPath, MangaStorage.kMangaJsonFileName);
    expect(after.chapterCount, 2, reason: '漫画的 chapterCount 是页数');
    expect(after.chaptersJson, '[]');
    expect(after.coverPath, payload.images.first.url);
    expect(after.mangaReadingMode, isNull, reason: 'null = 跟随页图比例自动判定');
    expect(after.extractDir, bookDir, reason: '三种格式共用同一个书目录');
    expect(after.author, '作者');
  });

  test('文字 EPUB 被挡住并给出具体原因，磁盘与行都不动', () async {
    writeExtractedImageEpub(bookDir, firstPageBody: '<p>これは本文です。</p>');
    await seedRow(
      format: BookFormat.epub,
      epubPath: 'novel.epub',
      chapterCount: 2,
      chaptersJson: '[{"id":"page1","characters":9}]',
    );

    expect(
      BookFormatRebuild.resolveVerdict(
        row: await row(),
        target: BookFormatTarget.manga,
      ).blocker,
      BookConvertBlocker.textOnlyBook,
    );
    await expectLater(
      BookFormatRebuild.convert(
        db: db,
        row: await row(),
        target: BookFormatTarget.manga,
      ),
      throwsA(isA<BookConvertBlockedException>()),
    );
    expect(
      File(p.join(bookDir, MangaStorage.kMangaJsonFileName)).existsSync(),
      isFalse,
    );
    expect((await row()).format, BookFormat.epub.dbValue);
  });

  test('EPUB 解压树没了 → sourceMissing（不是当成文字书含糊拒绝）', () async {
    await seedRow(
      format: BookFormat.epub,
      epubPath: 'gone.epub',
      chapterCount: 1,
      chaptersJson: '[]',
    );
    expect(
      BookFormatRebuild.resolveVerdict(
        row: await row(),
        target: BookFormatTarget.manga,
      ).blocker,
      BookConvertBlocker.sourceMissing,
    );
  });

  // ── 验收口径 ────────────────────────────────────────────────────────

  test(
      '验收①②③④：双向转化后身份逐字节不变、书架恰好一条、进度与最后阅读时刻不丢、'
      '阅读器路由跟着 format 走', () async {
    writeExtractedImageEpub(bookDir);
    await seedRow(
      format: BookFormat.epub,
      epubPath: 'scan.epub',
      chapterCount: 2,
      chaptersJson: '[{"id":"page1","href":"text/1.xhtml","characters":0}]',
      coverPath: 'OEBPS/images/1.png',
    );
    // 「最后阅读时刻」的真值载体：ReaderPositions.updatedAt（书架「最近阅读」按它排）。
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookKey: bookKey,
        sectionIndex: 3,
        normCharOffset: 4200,
        charOffset: const Value<int>(777),
        updatedAt: 1712345678901,
      ),
    );
    final int collectionId = await db.createMediaCollection('扫描本');
    await db.addToCollection(collectionId, MediaKind.epub, bookKey);

    final String identifierBefore =
        ReaderHibikiSource.mediaIdentifierFor(bookKey);

    await BookFormatRebuild.convert(
      db: db,
      row: await row(),
      target: BookFormatTarget.manga,
    );
    final EpubBookRow asManga = await row();

    // ① 身份逐字节不变。
    expect(asManga.bookKey, bookKey);
    expect(ReaderHibikiSource.mediaIdentifierFor(asManga.bookKey),
        identifierBefore);
    // ② 书架恰好一条（书架列的就是 EpubBooks 行）。
    expect(await db.getAllEpubBooks(), hasLength(1));
    // ③ 进度与最后阅读时刻不丢。
    final ReaderPositionRow posAsManga = (await db.getReaderPosition(bookKey))!;
    expect(posAsManga.sectionIndex, 3);
    expect(posAsManga.normCharOffset, 4200);
    expect(posAsManga.charOffset, 777);
    expect(posAsManga.updatedAt, 1712345678901);
    // ④ 跳回原文进正确阅读器。
    expect(
      ReaderHibikiSource.mediaSourceKeyFor(
          BookFormat.parseOrEpub(asManga.format)),
      MangaHibikiSource.kUniqueKey,
    );
    // 合集成员没断。
    expect(
        (await db.getCollectionItems(collectionId)).single.entryKey, bookKey);

    // ── 转回书 ──
    await BookFormatRebuild.convert(
      db: db,
      row: asManga,
      target: BookFormatTarget.book,
    );
    final EpubBookRow asBook = await row();

    expect(asBook.bookKey, bookKey, reason: '①往返后主键仍逐字节不变');
    expect(ReaderHibikiSource.mediaIdentifierFor(asBook.bookKey),
        identifierBefore);
    expect(await db.getAllEpubBooks(), hasLength(1), reason: '②往返后仍恰好一条');
    final ReaderPositionRow posAsBook = (await db.getReaderPosition(bookKey))!;
    expect(posAsBook.sectionIndex, 3);
    expect(posAsBook.charOffset, 777);
    expect(posAsBook.updatedAt, 1712345678901, reason: '③最后阅读时刻不丢');
    expect(
      ReaderHibikiSource.mediaSourceKeyFor(
          BookFormat.parseOrEpub(asBook.format)),
      ReaderHibikiSource.instance.uniqueKey,
      reason: '④转回书后必须回到 EPUB 阅读器',
    );
    expect(
        (await db.getCollectionItems(collectionId)).single.entryKey, bookKey);

    // 转回书是**重建**：chaptersJson 由重新解析解压树得到，不是留着漫画的 '[]'。
    expect(asBook.format, BookFormat.epub.dbValue);
    expect(asBook.chaptersJson, isNot('[]'));
    expect(jsonDecode(asBook.chaptersJson), hasLength(2));
    expect(asBook.chapterCount, 2);
    expect(asBook.mangaReadingMode, isNull, reason: '表约定：非漫画行恒 null');
  });

  test('往返不冲掉整卷 OCR：manga.json 仍完好时直接复用，不重建页图', () async {
    writeExtractedImageEpub(bookDir);
    await seedRow(
      format: BookFormat.epub,
      epubPath: 'scan.epub',
      chapterCount: 2,
      chaptersJson: '[{"id":"page1","characters":0}]',
    );
    await BookFormatRebuild.convert(
      db: db,
      row: await row(),
      target: BookFormatTarget.manga,
    );

    // 模拟整卷 OCR 跑完：往 manga.json 里塞识别结果。
    final File json = File(p.join(bookDir, MangaStorage.kMangaJsonFileName));
    final Map<String, Object?> decoded =
        jsonDecode(json.readAsStringSync()) as Map<String, Object?>;
    final List<Object?> pages = decoded['pages']! as List<Object?>;
    (pages.first! as Map<String, Object?>)['blocks'] = <Object?>[
      <String, Object?>{
        'box': <double>[1, 2, 3, 4],
        'vertical': true,
        'font_size': 12.0,
        'z_index': 0,
        'lines': <String>['小時間跑出來的識別結果'],
      },
    ];
    json.writeAsStringSync(jsonEncode(decoded));

    await BookFormatRebuild.convert(
      db: db,
      row: await row(),
      target: BookFormatTarget.book,
    );
    await BookFormatRebuild.convert(
      db: db,
      row: await row(),
      target: BookFormatTarget.manga,
    );

    final MokuroPayload after = parseMangaJson(json.readAsStringSync());
    expect(after.images.first.blocks, hasLength(1),
        reason: '转回书从不删漫画产物、转回漫画复用完好的 manga.json——'
            '否则一次往返就把用户跑了几小时的整卷 OCR 冲干净了');
    expect(after.images.first.blocks.single.lines.single, '小時間跑出來的識別結果');
  });

  test('绝不覆盖书自己的文件：书目录已有同名页图且无 manga.json 时硬失败', () async {
    writeExtractedImageEpub(bookDir);
    // 这本 EPUB 恰好自带顶层 images/page_000000.png（页图落点与它撞名）。
    final File owned =
        File(p.join(bookDir, MangaStorage.kImagesDirName, 'page_000000.png'));
    owned.parent.createSync(recursive: true);
    owned.writeAsBytesSync(const <int>[1, 2, 3]);
    await seedRow(
      format: BookFormat.epub,
      epubPath: 'scan.epub',
      chapterCount: 2,
      chaptersJson: '[]',
    );

    await expectLater(
      BookFormatRebuild.convert(
        db: db,
        row: await row(),
        target: BookFormatTarget.manga,
      ),
      throwsA(isA<MangaImportException>()),
    );
    expect(owned.readAsBytesSync(), <int>[1, 2, 3],
        reason: '宁可硬失败也不静默覆盖书自己的资源');
    expect((await row()).format, BookFormat.epub.dbValue);
  });

  // ── PDF ↔ 漫画（原生依赖注入） ──────────────────────────────────────

  test('PDF 转成漫画：逐页栅格化的页图落进书目录，行按页数写穿', () async {
    File(p.join(bookDir, PdfImporter.kPdfFileName))
        .writeAsBytesSync(const <int>[0x25, 0x50, 0x44, 0x46]);
    File(p.join(bookDir, PdfImporter.kCoverFileName))
        .writeAsBytesSync(pngBytes(20, 40));
    await seedRow(
      format: BookFormat.pdf,
      epubPath: PdfImporter.kPdfFileName,
      chapterCount: 3,
      chaptersJson: '[]',
      coverPath: PdfImporter.kCoverFileName,
    );
    BookFormatRebuild.debugPdfPageStager = (
      String pdfPath,
      Directory staging,
      void Function(int, int)? onProgress,
    ) async {
      for (int i = 0; i < 3; i++) {
        File(p.join(staging.path, 'page_${i.toString().padLeft(6, '0')}.png'))
            .writeAsBytesSync(pngBytes(50 + i, 100));
        onProgress?.call(i + 1, 3);
      }
      return 3;
    };

    final List<int> reported = <int>[];
    await BookFormatRebuild.convert(
      db: db,
      row: await row(),
      target: BookFormatTarget.manga,
      onProgress: (int done, int total) => reported.add(done),
    );

    final EpubBookRow after = await row();
    expect(after.format, BookFormat.manga.dbValue);
    expect(after.chapterCount, 3);
    expect(after.coverPath, 'images/page_000000.png');
    expect(reported, isNotEmpty, reason: '逐页进度要真的回报，否则长任务像卡死');
    final MokuroPayload payload = parseMangaJson(
      File(p.join(bookDir, MangaStorage.kMangaJsonFileName)).readAsStringSync(),
    );
    expect(payload.images.map((MokuroImage e) => e.size.width).toList(),
        <double>[50, 51, 52]);
  });

  test('漫画转回 PDF：指回 document.pdf、页数由 PDF 现算、封面回到 cover.png', () async {
    File(p.join(bookDir, PdfImporter.kPdfFileName))
        .writeAsBytesSync(const <int>[0x25, 0x50, 0x44, 0x46]);
    File(p.join(bookDir, PdfImporter.kCoverFileName))
        .writeAsBytesSync(pngBytes(20, 40));
    writeMangaArtifacts(bookDir, pageCount: 2);
    await seedRow(
      format: BookFormat.manga,
      epubPath: MangaStorage.kMangaJsonFileName,
      chapterCount: 2,
      chaptersJson: '[]',
      coverPath: 'images/page_000000.png',
    );
    BookFormatRebuild.debugPdfPageCounter = (String pdfPath) async => 42;

    await BookFormatRebuild.convert(
      db: db,
      row: await row(),
      target: BookFormatTarget.book,
    );

    final EpubBookRow after = await row();
    expect(after.format, BookFormat.pdf.dbValue);
    expect(after.epubPath, PdfImporter.kPdfFileName);
    expect(after.chapterCount, 42);
    expect(after.chaptersJson, '[]');
    expect(after.coverPath, PdfImporter.kCoverFileName);
    expect(after.mangaReadingMode, isNull);
    expect(
      ReaderHibikiSource.mediaSourceKeyFor(
          BookFormat.parseOrEpub(after.format)),
      ReaderPdfSource.kUniqueKey,
      reason: '转回 PDF 后必须进 PDF 阅读器，不是 EPUB 阅读器',
    );
  });

  test('从图片导入的漫画转不回书：没有书侧源产物就明说，不造假书', () async {
    writeMangaArtifacts(bookDir, pageCount: 2);
    await seedRow(
      format: BookFormat.manga,
      epubPath: MangaStorage.kMangaJsonFileName,
      chapterCount: 2,
      chaptersJson: '[]',
      coverPath: 'images/page_000000.png',
    );
    expect(
      BookFormatRebuild.resolveVerdict(
        row: await row(),
        target: BookFormatTarget.book,
      ).blocker,
      BookConvertBlocker.noOriginalFile,
    );
    await expectLater(
      BookFormatRebuild.convert(
        db: db,
        row: await row(),
        target: BookFormatTarget.book,
      ),
      throwsA(isA<BookConvertBlockedException>()),
    );
    expect((await row()).format, BookFormat.manga.dbValue);
  });

  test('已经是目标格式 → alreadyTarget（两个方向都挡）', () async {
    writeMangaArtifacts(bookDir, pageCount: 1);
    await seedRow(
      format: BookFormat.manga,
      epubPath: MangaStorage.kMangaJsonFileName,
      chapterCount: 1,
      chaptersJson: '[]',
    );
    expect(
      BookFormatRebuild.resolveVerdict(
        row: await row(),
        target: BookFormatTarget.manga,
      ).blocker,
      BookConvertBlocker.alreadyTarget,
    );
  });

  // ── 源产物探测：本文件真正的地雷区 ──────────────────────────────────

  test('EPUB 行的源产物是解压书目录，不是 extractDir/epubPath（那永远不存在）', () async {
    writeExtractedImageEpub(bookDir);
    await seedRow(
      format: BookFormat.epub,
      epubPath: 'scan.epub',
      chapterCount: 2,
      chaptersJson: '[]',
    );
    final BookConvertProbe probed = BookFormatRebuild.probeSource(await row());
    expect(File(p.join(bookDir, 'scan.epub')).existsSync(), isFalse,
        reason: '本仓的 EPUB 导入即解压，书目录里从来没有一份独立 .epub（BUG-088）');
    expect(probed.sourcePath, bookDir);
    expect(probed.probe.sourceExists, isTrue,
        reason: '照 extractDir/epubPath 探测的话这里会是 false，'
            '于是每一本 EPUB 都被判成 sourceMissing、转化全线不可用');
    expect(probed.probe.sourceIsImageArchive, isTrue);
  });

  test('漫画行的可还原书侧产物：优先 document.pdf，否则仍解析得通的解压树', () async {
    writeMangaArtifacts(bookDir, pageCount: 1);
    expect(BookFormatRebuild.recoverableBookSource(bookDir), isNull);

    writeExtractedImageEpub(bookDir);
    expect(BookFormatRebuild.recoverableBookSource(bookDir), bookDir);

    File(p.join(bookDir, PdfImporter.kPdfFileName)).writeAsBytesSync(<int>[1]);
    expect(BookFormatRebuild.recoverableBookSource(bookDir),
        p.join(bookDir, PdfImporter.kPdfFileName));
  });
}

/// 一张 [width]x[height] 的合法 PNG（页图解码要拿真实宽高）。
Uint8List pngBytes(int width, int height) => Uint8List.fromList(
      img.encodePng(img.Image(width: width, height: height)),
    );

/// 直接往 [dir] 铺一棵**已解压**的纯图 EPUB 树（container.xml + OPF + 两个只含
/// `<img>` 的 spine 页 + 两张图）。spine 顺序是 page2 → page1，好让「按 spine 铺页」
/// 与「按文件名排序」区分得开。
void writeExtractedImageEpub(
  String dir, {
  String firstPageBody = '<img src="../images/1.png"/>',
}) {
  void write(String relative, List<int> bytes) {
    final File file = File(p.join(dir, p.joinAll(relative.split('/'))));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  write('META-INF/container.xml', utf8.encode('''
<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
</container>'''));
  write('OEBPS/content.opf', utf8.encode('''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Scanned Volume 01</dc:title>
  </metadata>
  <manifest>
    <item id="page1" href="text/1.xhtml" media-type="application/xhtml+xml"/>
    <item id="page2" href="text/2.xhtml" media-type="application/xhtml+xml"/>
    <item id="image1" href="images/1.png" media-type="image/png"/>
    <item id="image2" href="images/2.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="page2"/>
    <itemref idref="page1"/>
  </spine>
</package>'''));
  write(
    'OEBPS/text/1.xhtml',
    utf8.encode(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body>$firstPageBody</body>'
      '</html>',
    ),
  );
  write(
    'OEBPS/text/2.xhtml',
    utf8.encode('<html xmlns="http://www.w3.org/1999/xhtml"><body>'
        '<img src="../images/2.png"/></body></html>'),
  );
  write('OEBPS/images/1.png', pngBytes(20, 40));
  write('OEBPS/images/2.png', pngBytes(30, 40));
}

/// 往 [dir] 铺一份最小可用的漫画产物（`manga.json` + `images/`），模拟
/// `.mokuro`/裸图片目录导入的漫画。
void writeMangaArtifacts(String dir, {required int pageCount}) {
  final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
  for (int i = 0; i < pageCount; i++) {
    final String rel = 'images/page_${i.toString().padLeft(6, '0')}.png';
    final File file = File(p.join(dir, p.joinAll(rel.split('/'))));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(pngBytes(60, 90));
    pages.add(<String, Object?>{
      'url': rel,
      'width': 60,
      'height': 90,
      'blocks': <Object?>[],
    });
  }
  File(p.join(dir, MangaStorage.kMangaJsonFileName))
      .writeAsStringSync(jsonEncode(<String, Object?>{'pages': pages}));
}
