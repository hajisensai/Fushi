import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/manga_overlay_html.dart';
import 'package:hibiki/src/media/manga/manga_reading_mode.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';

void main() {
  test('阅读器文档不再暴露框选 OCR 手势或回调', () {
    final String document = mangaWindowDocument(
      <MokuroImage>[
        const MokuroImage(
          url: 'page.jpg',
          size: Size(1000, 1600),
          blocks: <MokuroBlock>[],
        ),
      ],
      <String>['https://manga.local/img/page.jpg'],
      mode: MangaReadingMode.spread,
      spreadDirection: 'rtl',
      inlineSelectionJs: '/* selection */',
    );

    expect(document, isNot(contains('__mangaSetRescanMode')));
    expect(document, isNot(contains('onMangaBoxSelected')));
    expect(document, isNot(contains('manga-rescan-rect')));
    expect(document, isNot(contains('RESCAN')));
  });
}
