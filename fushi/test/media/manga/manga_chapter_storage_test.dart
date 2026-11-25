import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart'
    show MokuroBlock, MokuroImage, MokuroPayload, MokuroSize, parseMangaJson;
import 'package:path/path.dart' as p;

/// 章目录布局与「已下载」判据（设计稿 2026-09-12 §2.1）。
void main() {
  late Directory bookDir;

  setUp(() async {
    bookDir = await Directory.systemTemp.createTemp('fushi-chapter-storage-');
  });

  tearDown(() async {
    if (await bookDir.exists()) await bookDir.delete(recursive: true);
  });

  String chapterJson(List<String> urls) => jsonEncode(<String, Object?>{
    'pages': <Map<String, Object?>>[
      for (final String url in urls)
        <String, Object?>{
          'url': url,
          'width': 100,
          'height': 150,
          'blocks': <Object?>[],
        },
    ],
  });

  Future<Directory> writeChapter(
    String chapterKey, {
    required List<String> urls,
    List<String>? filesToWrite,
  }) async {
    final Directory dir = mangaChapterDirectory(bookDir.path, chapterKey);
    await mangaChapterImagesDirectory(dir).create(recursive: true);
    await mangaChapterJsonFile(dir).writeAsString(chapterJson(urls));
    for (final String url in filesToWrite ?? urls) {
      final File file = File(p.join(dir.path, url));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(<int>[0xff, 0xd8, 0xff, 1]);
    }
    return dir;
  }

  test('digest 与旧 chapterDirectory() 同算法：sha256(chapterKey) 前 24 位', () {
    const String key = '/manga/fixture/chapter-1?lang=ja';
    // 旧 `OnlineMangaLibraryService.chapterDirectory` 的推导，逐字节对拍。
    final String legacy = sha256
        .convert(utf8.encode(key))
        .toString()
        .substring(0, 24);
    expect(mangaChapterDigest(key), legacy);
    expect(mangaChapterDigest(key), hasLength(24));
    expect(
      mangaChapterDirectory(bookDir.path, key).path,
      p.join(bookDir.path, 'chapters', legacy),
    );
  });

  test('判据：manga.json + 非空 pages + 每页文件都在 → 已下载', () async {
    await writeChapter(
      '/c/1',
      urls: <String>['images/page-000001.jpg', 'images/page-000002.jpg'],
    );
    expect(await isChapterDownloaded(bookDir.path, '/c/1'), isTrue);
  });

  test('判据三种失败形态：无 manga.json / pages 为空 / 缺页文件', () async {
    // ① 目录在、页图在，但 manga.json 没写完（进程被杀）。
    final Directory noJson = mangaChapterDirectory(bookDir.path, '/c/nojson');
    await mangaChapterImagesDirectory(noJson).create(recursive: true);
    await File(
      p.join(noJson.path, 'images', 'page-000001.jpg'),
    ).writeAsBytes(<int>[1]);
    expect(await isChapterDownloaded(bookDir.path, '/c/nojson'), isFalse);

    // ② manga.json 在但 pages 为空（占位形状）。
    await writeChapter('/c/empty', urls: const <String>[]);
    expect(await isChapterDownloaded(bookDir.path, '/c/empty'), isFalse);

    // ③ manga.json 说三页、磁盘只有两页。
    await writeChapter(
      '/c/missing',
      urls: <String>[
        'images/page-000001.jpg',
        'images/page-000002.jpg',
        'images/page-000003.jpg',
      ],
      filesToWrite: <String>[
        'images/page-000001.jpg',
        'images/page-000002.jpg',
      ],
    );
    expect(await isChapterDownloaded(bookDir.path, '/c/missing'), isFalse);

    // ④ 坏 JSON 视同未下载，不抛。
    final Directory broken = mangaChapterDirectory(bookDir.path, '/c/broken');
    await broken.create(recursive: true);
    await mangaChapterJsonFile(broken).writeAsString('{not json');
    expect(await isChapterDownloaded(bookDir.path, '/c/broken'), isFalse);
  });

  test('穿越 url 视同缺页：判据不会被 ../ 骗成已下载', () async {
    final Directory dir = mangaChapterDirectory(bookDir.path, '/c/evil');
    await mangaChapterImagesDirectory(dir).create(recursive: true);
    // 文件真的存在于章目录外；url 越界应当判 false。
    await File(p.join(bookDir.path, 'outside.jpg')).writeAsBytes(<int>[1]);
    await mangaChapterJsonFile(
      dir,
    ).writeAsString(chapterJson(<String>['../../outside.jpg']));
    expect(await isChapterDownloaded(bookDir.path, '/c/evil'), isFalse);
  });

  test('deleteChapterDownload 整目录删除，不存在时静默', () async {
    final Directory dir = await writeChapter(
      '/c/del',
      urls: <String>['images/page-000001.jpg'],
    );
    expect(dir.existsSync(), isTrue);
    await deleteChapterDownload(bookDir.path, '/c/del');
    expect(dir.existsSync(), isFalse);
    expect(await isChapterDownloaded(bookDir.path, '/c/del'), isFalse);
    await expectLater(deleteChapterDownload(bookDir.path, '/c/del'), completes);
  });

  test('downloadedChapterKeys 只回已完整下载的那些', () async {
    await writeChapter('/c/a', urls: <String>['images/page-000001.jpg']);
    await writeChapter('/c/b', urls: const <String>[]);
    expect(
      await downloadedChapterKeys(bookDir.path, <String>[
        '/c/a',
        '/c/b',
        '/c/c',
      ]),
      <String>{'/c/a'},
    );
  });

  test('mangaChapterKeysByDirectory 与逐章 p.equals 同口径（gap-mangamisc-4）', () {
    final List<String> keys = <String>['/c/1', '/c/2', '/c/3'];
    final index = mangaChapterKeysByDirectory(bookDir.path, keys);
    for (final String key in keys) {
      final String dir = mangaChapterDirectory(bookDir.path, key).path;
      expect(index[dir], key);
      // 未规范化的写法（多余的 `.` / `..`）按 p.equals 仍是同一目录。
      final String messy = p.join(
        p.dirname(dir),
        '.',
        'x',
        '..',
        p.basename(dir),
      );
      expect(p.equals(messy, dir), isTrue);
      expect(index[messy], key);
    }
    if (Platform.isWindows) {
      final String dir = mangaChapterDirectory(bookDir.path, '/c/2').path;
      expect(p.equals(dir.toUpperCase(), dir), isTrue);
      expect(index[dir.toUpperCase()], '/c/2');
    }
    expect(index[p.join(bookDir.path, 'chapters', 'nope')], isNull);
  });

  test(
    'readDownloadedChapterPayload 用调用方的 parse，并把 payload 交回（manga-4）',
    () async {
      final Directory dir = await writeChapter(
        '/c/1',
        urls: <String>['images/page-000001.jpg'],
      );
      int parses = 0;
      final payload = await readDownloadedChapterPayload(
        dir,
        parse: (String source) async {
          parses++;
          return parseMangaJson(source);
        },
      );
      expect(parses, 1);
      expect(payload, isNotNull);
      expect(payload!.images.single.url, 'images/page-000001.jpg');
    },
  );

  group('源端页身份旁注（review-interconnect-page-id-on-download）', () {
    MokuroPayload payloadOf(List<(String, int, int)> pages) => MokuroPayload(
      images: <MokuroImage>[
        for (final (String url, int width, int height) in pages)
          MokuroImage(
            url: url,
            size: MokuroSize(width.toDouble(), height.toDouble()),
            blocks: const <MokuroBlock>[],
          ),
      ],
    );

    final MokuroPayload downloaded = payloadOf(<(String, int, int)>[
      ('images/page-000001.png', 100, 150),
      ('images/page-000002.png', 101, 151),
      ('images/page-000003.png', 102, 152),
    ]);

    test('配对 → 落盘 → 读回：逐页认出源端身份，源端没给身份的页为 null', () async {
      final Directory dir = mangaChapterDirectory(bookDir.path, '/c/1')
        ..createSync(recursive: true);
      mangaChapterSourcePagesFile(dir).writeAsStringSync(
        encodeMangaChapterSourcePages(
          mangaChapterSourcePagesOf(downloaded, <String?>['a', null, 'c']),
        ),
      );
      final List<MangaChapterSourcePage?> pages =
          await readMangaChapterSourcePages(dir);
      expect(
        <String?>[
          for (int i = 0; i < 4; i++)
            mangaChapterSourcePageKey(pages, downloaded, i),
        ],
        <String?>['a', null, 'c', null],
      );
    });

    test('manga.json 换过内容（url 或尺寸对不上）的页不认旁注', () {
      final List<MangaChapterSourcePage?> pages = mangaChapterSourcePagesOf(
        downloaded,
        <String?>['a', 'b', 'c'],
      );
      final MokuroPayload rewritten = payloadOf(<(String, int, int)>[
        ('images/page-000001.png', 100, 150),
        ('images/page-000002.png', 201, 151),
        ('images/other.png', 102, 152),
      ]);
      expect(
        <String?>[
          for (int i = 0; i < 3; i++)
            mangaChapterSourcePageKey(pages, rewritten, i),
        ],
        <String?>['a', null, null],
      );
    });

    test('页数对不上整份不记；没有旁注 / 坏旁注按「没有」', () async {
      expect(
        mangaChapterSourcePagesOf(downloaded, <String?>['a', 'b']),
        isEmpty,
      );
      final Directory dir = mangaChapterDirectory(bookDir.path, '/c/2')
        ..createSync(recursive: true);
      expect(await readMangaChapterSourcePages(dir), isEmpty);
      mangaChapterSourcePagesFile(dir).writeAsStringSync('{not json');
      expect(await readMangaChapterSourcePages(dir), isEmpty);
      mangaChapterSourcePagesFile(
        dir,
      ).writeAsStringSync('{"version":2,"pages":[]}');
      expect(await readMangaChapterSourcePages(dir), isEmpty);
    });
  });
}
