import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/online_manga_reader_session.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// BUG-4243：在线直读章的「全部页面」网格 / 拖动气泡缩略图全是页码占位，连已经
/// 看过（会话已落盘）的页也没有。payload 的 url 是不带扩展名的占位名，按 url 拼路径
/// 永远落空；缩略图必须认会话缓存里已落盘的那份。
void main() {
  late Directory cacheRoot;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('manga_thumb_bug4243_');
  });

  tearDown(() async {
    if (await cacheRoot.exists()) await cacheRoot.delete(recursive: true);
  });

  final Uint8List png = Uint8List.fromList(
    img.encodePng(img.Image(width: 30, height: 40)),
  );

  MokuroPayload streamingPayload(String chapterDirName, int pages) =>
      MokuroPayload(
        images: <MokuroImage>[
          for (int index = 0; index < pages; index++)
            MokuroImage(
              url: MangaFushiPage.streamingPageUrl(chapterDirName, index),
              size: const MokuroSize(1000, 1414),
              blocks: const <MokuroBlock>[],
            ),
        ],
      );

  test('在线直读章：已取到的页给出会话缓存文件，没取到的页 null（不发请求）', () async {
    final List<int> fetched = <int>[];
    final OnlineMangaReaderSession session =
        await OnlineMangaReaderSession.open(
          cacheRoot: cacheRoot,
          bookKey: 'book-1',
          chapterKey: '/chapter/1',
          pageIdentities: <String>[for (int i = 0; i < 4; i++) 'id-$i'],
          fetchPage: (int index) async {
            fetched.add(index);
            return png;
          },
          prefetchAhead: 0,
          prefetchBehind: 0,
        );
    addTearDown(session.close);

    final MokuroPayload payload = streamingPayload('chapter-abc', 4);
    // 与阅读器一致：在线直读章的 imagesDir 就是会话缓存目录。
    final String imagesDir = session.directory.path;

    await session.page(1);
    await session.debugWaitForIdle();
    expect(fetched, <int>[1]);

    // 修复前缩略图走的路径：按占位 url 拼，已缓存的页也落空。
    expect(MangaFushiPage.resolveMangaPageImage(payload, imagesDir, 1), isNull);

    final String? cached = MangaFushiPage.cachedMangaPageImage(
      payload,
      imagesDir,
      session,
      1,
    );
    expect(cached, isNotNull);
    expect(File(cached!).existsSync(), isTrue);
    expect(p.basename(cached), startsWith('page-000002'));

    expect(
      MangaFushiPage.cachedMangaPageImage(payload, imagesDir, session, 0),
      isNull,
    );
    expect(
      MangaFushiPage.cachedMangaPageImage(payload, imagesDir, session, 9),
      isNull,
    );
    // 查缩略图不为没取到的页发请求。
    expect(fetched, <int>[1]);
  });

  test('本地卷 / 已下载章：仍按 manga.json url 解析', () async {
    final Directory images = await Directory(
      p.join(cacheRoot.path, 'images'),
    ).create(recursive: true);
    await File(p.join(images.path, 'p1.png')).writeAsBytes(png);
    final MokuroPayload payload = MokuroPayload(
      images: <MokuroImage>[
        MokuroImage(
          url: 'images/p1.png',
          size: const MokuroSize(30, 40),
          blocks: const <MokuroBlock>[],
        ),
      ],
    );

    final String? path = MangaFushiPage.cachedMangaPageImage(
      payload,
      images.path,
      null,
      0,
    );
    expect(path, isNotNull);
    expect(p.equals(path!, p.join(images.path, 'p1.png')), isTrue);
  });
}
