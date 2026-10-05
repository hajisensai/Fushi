import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:image/image.dart' as img;

void main() {
  test('local reader session serves managed pages and blocks traversal',
      () async {
    final Directory root =
        await Directory.systemTemp.createTemp('hibiki-local-manga-reader-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final Directory images =
        Directory('${root.path}${Platform.pathSeparator}images');
    await images.create();
    await File('${images.path}${Platform.pathSeparator}page.png').writeAsBytes(
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
    );
    await File('${root.path}${Platform.pathSeparator}secret.jpg').writeAsBytes(
      <int>[0xff, 0xd8, 0xff],
    );

    final MangaReaderSession session = await LocalMangaPageProvider(
      imagesRoot: images,
      relativePaths: const <String>['page.png', '../secret.jpg'],
    ).open();
    expect(session.pageCount, 2);
    expect((await session.page(0)).contentType, 'image/png');
    expect((await session.localFile(0))?.path, endsWith('page.png'));
    await expectLater(
      session.page(1),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'PATH_TRAVERSAL',
        ),
      ),
    );

    await session.close();
    await expectLater(
      session.page(0),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException error) => error.code,
          'code',
          'SESSION_CLOSED',
        ),
      ),
    );
  });

  test('decodes the real landscape and portrait page dimensions', () async {
    final ({int width, int height})? landscape = await mangaImageDimensions(
      Uint8List.fromList(
        img.encodePng(img.Image(width: 1200, height: 700)),
      ),
    );
    final ({int width, int height})? portrait = await mangaImageDimensions(
      Uint8List.fromList(
        img.encodePng(img.Image(width: 720, height: 1280)),
      ),
    );

    expect(landscape, (width: 1200, height: 700));
    expect(portrait, (width: 720, height: 1280));
  });

  // BUG-2962：阅读器每个页图请求（WebView 拦截 / 面板检测）都走 page()，取宽高
  // 以前整张纯 Dart 解码（2400×3400 一页在桌面就要 0.5~0.7 s），大图卷一翻页就是
  // 数秒 CPU，iOS 自定义 scheme 没有 HTTP 缓存、每次重载窗口都重付。宽高只读文件
  // 头即可：这里给一张「文件头完整、像素段被截断」的 JPEG——整张解码必然失败
  // （旧实现返回 null），头探测照样给出宽高，证明 page() 不再解像素。
  test('page dimensions come from the header without decoding pixels',
      () async {
    final Uint8List full = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 1600, height: 2400), quality: 90),
    );
    final Uint8List headerOnly = Uint8List.fromList(<int>[
      ...full.sublist(0, full.length ~/ 3),
    ]);
    bool wholeImageDecodes;
    try {
      wholeImageDecodes = img.decodeJpg(headerOnly) != null;
    } on Object {
      wholeImageDecodes = false;
    }
    expect(wholeImageDecodes, isFalse,
        reason: 'fixture must be undecodable as a whole image');

    expect(await mangaImageDimensions(headerOnly), (width: 1600, height: 2400));

    final Directory root =
        await Directory.systemTemp.createTemp('hibiki-local-manga-probe-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    await File('${root.path}${Platform.pathSeparator}p.jpg')
        .writeAsBytes(headerOnly);
    final MangaReaderSession session = await LocalMangaPageProvider(
      imagesRoot: root,
      relativePaths: const <String>['p.jpg'],
    ).open();
    addTearDown(session.close);
    final MangaPageBytes page = await session.page(0);
    expect(page.contentType, 'image/jpeg');
    expect((page.width, page.height), (1600, 2400));
  });
}
