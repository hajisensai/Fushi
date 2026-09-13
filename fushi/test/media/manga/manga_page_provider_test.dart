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
}
