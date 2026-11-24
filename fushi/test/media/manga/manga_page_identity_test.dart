import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/manga/manga_page_identity.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 一卷 manga.json：每页一个文字块，文字 = [texts] 里对应的那项（null = 无块）。
MokuroPayload _payload(List<String> urls, List<String?> texts) =>
    parseMangaJson(
      jsonEncode(<String, Object?>{
        'pages': <Map<String, Object?>>[
          for (int i = 0; i < urls.length; i++)
            <String, Object?>{
              'url': urls[i],
              'width': 100,
              'height': 150,
              'blocks': <Object?>[
                if (texts[i] != null)
                  <String, Object?>{
                    'box': <int>[10, 20, 60, 120],
                    'vertical': true,
                    'font_size': 20,
                    'z_index': 0,
                    'lines': <String>[texts[i]!],
                  },
              ],
            },
        ],
      }),
    );

String? _textOf(MokuroImage page) =>
    page.blocks.isEmpty ? null : page.blocks.single.lines.join();

void main() {
  group('BUG-5384 mangaPageId：两边的 url 写法得同一个身份', () {
    test('导入器写法、旧 .mokuro 裸名、任务 relativeUrl 收敛到同一值', () {
      expect(mangaPageId('images/p001.jpg'), 'images/p001.jpg');
      expect(mangaPageId('p001.jpg'), 'images/p001.jpg');
      expect(mangaPageId('./images/p001.jpg'), 'images/p001.jpg');
      expect(mangaPageId(r'images\vol1\p001.jpg'), 'images/vol1/p001.jpg');
      expect(mangaPageId('/images/vol1/p001.jpg'), 'images/vol1/p001.jpg');
    });

    test('mangaPageIndexOf 按身份找下标，不在表里为 null', () {
      const List<String> table = <String>['p001.jpg', 'images/p002.jpg'];
      expect(mangaPageIndexOf(table, 'images/p002.jpg'), 1);
      expect(mangaPageIndexOf(table, 'images/p001.jpg'), 0);
      expect(mangaPageIndexOf(table, 'images/000_cover.jpg'), isNull);
    });
  });

  group('BUG-5384 alignMangaOcrResult：结果按身份并进卷的页表', () {
    test('目录多一张不在页表里的图：结果落在正确页，页表与页数不变', () {
      // 卷：3 页。任务目录里多一张排在最前的图，任务的页号整体后移一位。
      final MokuroPayload volume = _payload(
        <String>['images/p001.jpg', 'images/p002.jpg', 'images/p003.jpg'],
        <String?>[null, null, '旧三'],
      );
      final MokuroPayload result = _payload(
        <String>['images/000_cover.jpg', 'images/p001.jpg', 'images/p002.jpg'],
        <String?>['封面字', '一', '二'],
      );

      final MangaOcrAlignment aligned = alignMangaOcrResult(
        volume: volume,
        result: result,
      );

      expect(
        aligned.payload.images.map((MokuroImage page) => page.url),
        <String>['images/p001.jpg', 'images/p002.jpg', 'images/p003.jpg'],
        reason: '页表与页序以卷为准，多出的图不进页表',
      );
      expect(aligned.payload.images.map(_textOf), <String?>[
        '一',
        '二',
        '旧三',
      ], reason: '每页拿到的是它自己那张图的结果；结果里缺的页保持原样');
      expect(aligned.matched, 2);
      expect(aligned.dropped, 1);
    });

    test('旧 .mokuro 裸名页表也能对上任务的 images/ 路径', () {
      final MokuroPayload volume = _payload(
        <String>['p001.jpg', 'p002.jpg'],
        <String?>[null, null],
      );
      final MokuroPayload result = _payload(
        <String>['images/p002.jpg', 'images/p001.jpg'],
        <String?>['二', '一'],
      );
      final MangaOcrAlignment aligned = alignMangaOcrResult(
        volume: volume,
        result: result,
      );
      expect(aligned.payload.images.map(_textOf), <String?>['一', '二']);
      expect(aligned.matched, 2);
      expect(aligned.dropped, 0);
    });

    test('一页都对不上：抛错，不把别的页表写进这卷', () {
      final MokuroPayload volume = _payload(
        <String>['images/p001.jpg'],
        <String?>[null],
      );
      final MokuroPayload result = _payload(
        <String>['images/other.jpg'],
        <String?>['别卷'],
      );
      expect(
        () => alignMangaOcrResult(volume: volume, result: result),
        throwsStateError,
      );
    });
  });
}
