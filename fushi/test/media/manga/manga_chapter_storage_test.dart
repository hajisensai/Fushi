import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:path/path.dart' as p;

/// 章目录布局与「已下载」判据（设计稿 2026-09-12 §2.1）。
void main() {
  late Directory bookDir;

  setUp(() async {
    bookDir = await Directory.systemTemp.createTemp('hibiki-chapter-storage-');
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
    final String legacy =
        sha256.convert(utf8.encode(key)).toString().substring(0, 24);
    expect(mangaChapterDigest(key), legacy);
    expect(mangaChapterDigest(key), hasLength(24));
    expect(
      mangaChapterDirectory(bookDir.path, key).path,
      p.join(bookDir.path, 'chapters', legacy),
    );
  });

  test('判据：manga.json + 非空 pages + 每页文件都在 → 已下载', () async {
    await writeChapter('/c/1', urls: <String>[
      'images/page-000001.jpg',
      'images/page-000002.jpg',
    ]);
    expect(await isChapterDownloaded(bookDir.path, '/c/1'), isTrue);
  });

  test('判据三种失败形态：无 manga.json / pages 为空 / 缺页文件', () async {
    // ① 目录在、页图在，但 manga.json 没写完（进程被杀）。
    final Directory noJson = mangaChapterDirectory(bookDir.path, '/c/nojson');
    await mangaChapterImagesDirectory(noJson).create(recursive: true);
    await File(p.join(noJson.path, 'images', 'page-000001.jpg'))
        .writeAsBytes(<int>[1]);
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
    await mangaChapterJsonFile(dir)
        .writeAsString(chapterJson(<String>['../../outside.jpg']));
    expect(await isChapterDownloaded(bookDir.path, '/c/evil'), isFalse);
  });

  test('deleteChapterDownload 整目录删除，不存在时静默', () async {
    final Directory dir = await writeChapter('/c/del', urls: <String>[
      'images/page-000001.jpg',
    ]);
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
      await downloadedChapterKeys(
          bookDir.path, <String>['/c/a', '/c/b', '/c/c']),
      <String>{'/c/a'},
    );
  });
}
