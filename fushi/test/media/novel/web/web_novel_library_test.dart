// 网页小说书：Rust 提取 / 连载会话（真原生库，fushi_web_core）→ 组装 EPUB → 入库 / 就地
// 重建 → 阅读器按需取下一章 → 开书前补「下一章」占位。用真实页面快照
// （native/fushi_web_core/tests/vectors/article/inputs/）驱动，入库 / 重建换成真解压的假实现
// （与 lnreader_online_book_test 同一做法），取页 / 取图换成测试缝。
//
// 🔴 本文件不调 `TestWidgetsFlutterBinding.ensureInitialized()`（同 lnreader_online_book_test）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart'
    show kLnReaderPendingChapterAttribute, lnReaderOnlineChapterFile;
import 'package:fushi/src/media/novel/web/web_novel_library.dart';
import 'package:fushi/src/media/novel/web/web_novel_page_fetcher.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:fushi_web_core/testing.dart';
import 'package:path/path.dart' as p;

/// 1×1 PNG。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void _unzipInto(Uint8List bytes, String dir) {
  for (final ArchiveFile file in ZipDecoder().decodeBytes(bytes)) {
    if (!file.isFile) continue;
    final File out = File(p.join(dir, file.name));
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(file.content as List<int>);
  }
}

class _FakeFetcher implements WebNovelPageFetcher {
  _FakeFetcher(this.pages);

  /// 请求的 URL → (返回的页, 最终地址)。
  final Map<String, WebNovelFetchedPage> pages;
  final List<String> requested = <String>[];

  @override
  Future<WebNovelFetchedPage> fetch(Uri url) async {
    requested.add(url.toString());
    final WebNovelFetchedPage? page = pages[url.toString()];
    if (page == null) throw WebNovelFetchException('no fixture for $url');
    return page;
  }
}

void main() {
  final Directory vectors = locateWebCoreVectors()!;
  Uint8List fixture(String name) =>
      File(p.join(vectors.path, 'article', 'inputs', name)).readAsBytesSync();

  const String ch1Url = 'https://ncode.syosetu.com/n9669bk/1/';
  const String ch2Url = 'https://ncode.syosetu.com/n9669bk/2/';
  const String ch10Url = 'https://ncode.syosetu.com/n9669bk/10/';
  const String pending = 'PENDING';
  const String nextTitle = 'NEXT';

  late Directory root;
  late FushiDatabase db;
  late int imports;
  late int rebuilds;

  setUp(() async {
    imports = 0;
    rebuilds = 0;
    root = await Directory.systemTemp.createTemp('web_novel_library_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<({int chapterCount, String chaptersJson, String? coverPath})>
  rebuildInPlace({
    required String epubFilePath,
    required String extractDir,
  }) async {
    rebuilds++;
    Directory(extractDir).deleteSync(recursive: true);
    _unzipInto(File(epubFilePath).readAsBytesSync(), extractDir);
    final int count = Directory(p.join(extractDir, 'OEBPS'))
        .listSync()
        .where(
          (FileSystemEntity e) => p.basename(e.path).startsWith('chapter-'),
        )
        .length;
    return (
      chapterCount: count,
      chaptersJson: jsonEncode(<Object?>[
        for (int i = 0; i < count; i++)
          <String, Object?>{'href': 'OEBPS/chapter-${i + 1}.xhtml'},
      ]),
      coverPath: null,
    );
  }

  WebNovelLibrary library({WebNovelImageFetch? fetchImage}) => WebNovelLibrary(
    database: db,
    fetchImage: fetchImage ?? (Uri url, {required Uri referer}) async => null,
    importEpub:
        ({
          required FushiDatabase db,
          required Uint8List bytes,
          required String fileName,
          required DuplicatePolicy policy,
        }) async {
          imports++;
          final String dir = p.join(root.path, 'book$imports');
          _unzipInto(bytes, dir);
          final int count = Directory(p.join(dir, 'OEBPS'))
              .listSync()
              .where(
                (FileSystemEntity e) =>
                    p.basename(e.path).startsWith('chapter-'),
              )
              .length;
          await db.insertEpubBook(
            EpubBooksCompanion.insert(
              bookKey: 'book$imports',
              title: p.basenameWithoutExtension(fileName),
              epubPath: fileName,
              extractDir: dir,
              chapterCount: count,
              chaptersJson: '[]',
              importedAt: 0,
            ),
          );
          return 'book$imports';
        },
    rebuildInPlace: rebuildInPlace,
  );

  /// 浏览器动作的核心路径：开会话（有书用书的快照）→ 喂页 → 落书。
  Future<String> readPage(
    WebNovelLibrary lib,
    String fixtureName,
    String url,
  ) async {
    final String workKey = WebArticleExtractor.workKeyForUrl(Uri.parse(url))!;
    final EpubBookRow? existing = await lib.findBook(workKey);
    final WebNovelSession session = WebNovelSession.open(
      snapshot: WebNovelSnapshot.tryParse(existing?.sourceMetadata)?.raw,
    );
    try {
      final WebNovelIngest ingest = await session.ingest(
        fixture(fixtureName),
        Uri.parse(url),
      );
      expect(ingest.status.accepted, isTrue, reason: fixtureName);
      return await lib.save(
        snapshot: session.snapshot(),
        chapterIndex: ingest.index!,
        content: await lib.materialize(ingest.article),
        pendingText: pending,
        nextChapterTitle: nextTitle,
        existing: existing,
      );
    } finally {
      session.close();
    }
  }

  String chapterText(EpubBookRow row, int index) =>
      lnReaderOnlineChapterFile(row.extractDir, index).readAsStringSync();

  test('新书：正文进第 1 章，末尾挂「下一章」占位，快照原样进书行', () async {
    final WebNovelLibrary lib = library();
    final String bookKey = await readPage(
      lib,
      'syosetu_n9669bk_1.html',
      ch1Url,
    );
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(imports, 1);
    expect(row.chapterCount, 2);
    final WebNovelSnapshot snapshot = WebNovelSnapshot.tryParse(
      row.sourceMetadata,
    )!;
    expect(snapshot.workKey, 'ncode.syosetu.com/n9669bk');
    expect(snapshot.tailNext, ch2Url);
    expect(chapterText(row, 0), contains('俺は34歳住所不定無職。'));
    expect(chapterText(row, 0), contains('<h2>プロローグ</h2>'));
    expect(chapterText(row, 1), contains(kLnReaderPendingChapterAttribute));
    expect(chapterText(row, 1), contains(pending));
    // 书名取作品名，dc:identifier 是作品身份。
    final String opf = File(
      p.join(row.extractDir, 'OEBPS', 'content.opf'),
    ).readAsStringSync();
    expect(opf, contains('web-novel:ncode.syosetu.com/n9669bk'));
    expect(opf, contains('無職転生'));
    expect(opf, contains('<dc:language>ja</dc:language>'));
  });

  test('同一部作品再点另一章：就地重建并章，已取过的章原样保留、书不变', () async {
    final WebNovelLibrary lib = library();
    final String bookKey = await readPage(
      lib,
      'syosetu_n9669bk_1.html',
      ch1Url,
    );
    final String again = await readPage(
      lib,
      'syosetu_n9669bk_10.html',
      ch10Url,
    );
    expect(again, bookKey);
    expect(imports, 1);
    expect(rebuilds, 1);
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final WebNovelSnapshot snapshot = WebNovelSnapshot.tryParse(
      row.sourceMetadata,
    )!;
    expect(snapshot.chapters.map((WebNovelChapter c) => c.url), <String>[
      ch1Url,
      ch10Url,
    ]);
    expect(chapterText(row, 0), contains('俺は34歳住所不定無職。'));
    expect(
      chapterText(row, 1),
      contains('<ruby>御神体<rp>(</rp><rt>パンツ</rt><rp>)</rp></ruby>'),
    );
    // 末章（第 10 话）的下一章是第 11 话：占位挂在第 3 项。
    expect(row.chapterCount, 3);
    expect(chapterText(row, 2), contains(kLnReaderPendingChapterAttribute));
  });

  test('阅读器读到「下一章」占位：无界面取页 → Rust 并章 → 写回正文与新快照；'
      '下次开书补新的占位', () async {
    final WebNovelLibrary lib = library();
    final String bookKey = await readPage(
      lib,
      'syosetu_n9669bk_1.html',
      ch1Url,
    );
    EpubBookRow row = (await db.getEpubBook(bookKey))!;
    // 第 2 话的页用第 10 话的快照内容冒充（会话只看 URL / 链接 / 指纹）。
    final _FakeFetcher fetcher = _FakeFetcher(<String, WebNovelFetchedPage>{
      ch2Url: (
        html: fixture('syosetu_n9669bk_10.html'),
        url: Uri.parse(ch2Url),
      ),
    });
    final WebNovelChapterLoader loader = WebNovelChapterLoader(
      database: db,
      library: lib,
      fetcher: fetcher,
      bookKey: bookKey,
      extractDir: row.extractDir,
    );
    final String placeholder = lnReaderOnlineChapterFile(
      row.extractDir,
      1,
    ).path;
    expect(loader.chapterIndexForFile(placeholder), 1);
    expect(await loader.ensureLoaded(placeholder), isTrue);
    expect(fetcher.requested, <String>[ch2Url]);
    expect(
      chapterText(row, 1),
      isNot(contains(kLnReaderPendingChapterAttribute)),
    );
    expect(chapterText(row, 1), contains('ゼニスの妊娠がわかった。'));
    // 已是正文：再请求不取。
    expect(await loader.ensureLoaded(placeholder), isFalse);

    row = (await db.getEpubBook(bookKey))!;
    final WebNovelSnapshot snapshot = WebNovelSnapshot.tryParse(
      row.sourceMetadata,
    )!;
    expect(snapshot.chapters.length, 2);
    expect(snapshot.tailNext, 'https://ncode.syosetu.com/n9669bk/11/');
    // spine 此时没有新的占位（阅读器开着这本书时不改 spine）。
    expect(row.chapterCount, 2);

    final EpubBookRow? prepared = await prepareWebNovelBookForReading(
      database: db,
      row: row,
      pendingText: pending,
      nextChapterTitle: nextTitle,
      library: lib,
    );
    expect(prepared!.chapterCount, 3);
    expect(chapterText(prepared, 1), contains('ゼニスの妊娠がわかった。'));
    expect(
      chapterText(prepared, 2),
      contains(kLnReaderPendingChapterAttribute),
    );
    // 已有占位：不再重建。
    final int before = rebuilds;
    expect(
      await lib.ensureTrailingPlaceholder(
        prepared,
        pendingText: pending,
        nextChapterTitle: nextTitle,
      ),
      isFalse,
    );
    expect(rebuilds, before);
  });

  test('取回的是验证页 / 不是这一章：拒收，占位页原样保留', () async {
    final WebNovelLibrary lib = library();
    final String bookKey = await readPage(
      lib,
      'syosetu_n9669bk_1.html',
      ch1Url,
    );
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final WebNovelChapterLoader loader = WebNovelChapterLoader(
      database: db,
      library: lib,
      fetcher: _FakeFetcher(<String, WebNovelFetchedPage>{
        ch2Url: (
          html: Uint8List.fromList(
            utf8.encode('<html><body>Just a moment...</body></html>'),
          ),
          url: Uri.parse(ch2Url),
        ),
      }),
      bookKey: bookKey,
      extractDir: row.extractDir,
    );
    final String placeholder = lnReaderOnlineChapterFile(
      row.extractDir,
      1,
    ).path;
    await expectLater(
      loader.ensureLoaded(placeholder),
      throwsA(isA<WebNovelChapterRejected>()),
    );
    expect(chapterText(row, 1), contains(kLnReaderPendingChapterAttribute));
    expect((await db.getEpubBook(bookKey))!.sourceMetadata, row.sourceMetadata);
  });

  test('正文图：取到的换成书内文件名，取不到的删掉引用', () async {
    final WebNovelLibrary lib = library(
      fetchImage: (Uri url, {required Uri referer}) async {
        expect(referer.toString(), 'https://a.example/book/1/2.html');
        return url.path.endsWith('ok.png') ? _png : null;
      },
    );
    final WebArticle article = await WebArticleExtractor.extract(
      Uint8List.fromList(
        utf8.encode(
          '<html><body><div id="content">'
          '<p>挿絵の前の段落です。これはテスト用の本文で、二十文字を超えるように書いています。</p>'
          '<p><img src="/img/ok.png" alt="挿絵"></p>'
          '<p><img src="/img/missing.png"></p>'
          '<p>挿絵の後の段落です。こちらも十分な長さの本文を書いておきます。</p>'
          '</div></body></html>',
        ),
      ),
      Uri.parse('https://a.example/book/1/2.html'),
    );
    expect(article.images, hasLength(2));
    final WebNovelChapterContent content = await lib.materialize(article);
    expect(content.images, hasLength(1));
    expect(content.images.single.mediaType, 'image/png');
    expect(content.images.single.fileName, startsWith('images/w'));
    expect(content.xhtml, contains('src="${content.images.single.fileName}"'));
    expect(content.xhtml, isNot(contains(kWebArticleImagePlaceholderPrefix)));
  });

  test('只有网页小说书才有取章加载器（普通书 / LNReader 书为 null）', () async {
    final WebNovelLibrary lib = library();
    final String bookKey = await readPage(
      lib,
      'syosetu_n9669bk_1.html',
      ch1Url,
    );
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(
      webNovelChapterLoaderFor(
        row: row,
        extractDir: row.extractDir,
        database: db,
      ),
      isNotNull,
    );
    final EpubBookRow plain = row.copyWith(
      sourceMetadata: const Value<String?>(null),
    );
    expect(
      webNovelChapterLoaderFor(
        row: plain,
        extractDir: row.extractDir,
        database: db,
      ),
      isNull,
    );
    expect(
      await prepareWebNovelBookForReading(
        database: db,
        row: plain,
        pendingText: pending,
        nextChapterTitle: nextTitle,
      ),
      same(plain),
    );
  });
}
