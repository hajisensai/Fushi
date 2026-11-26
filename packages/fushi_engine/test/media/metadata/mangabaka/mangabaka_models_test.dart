import 'dart:io';

import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_models.dart';
import 'package:test/test.dart';

String _fixture(String name) =>
    File('test/fixtures/mangabaka/$name').readAsStringSync();

void main() {
  group('parseMangaBakaSearch', () {
    test('呪術廻戦: 真实响应的 id / 类型 / 日文名 / final_volume / 作者', () {
      final MangaBakaPage<MangaBakaSeries> page = parseMangaBakaSearch(
        _fixture('mb_search_jujutsu.json'),
      );
      expect(page.items.length, 10);
      final MangaBakaSeries first = page.items.first;
      expect(first.id, 410304);
      expect(first.nativeTitle, '呪術廻戦≡');
      expect(first.finalVolume, 3);
      final MangaBakaSeries main = page.items[1];
      expect(main.id, 6199);
      expect(main.nativeTitle, '呪術廻戦');
      expect(main.type, 'manga');
      expect(main.finalVolume, 30);
      expect(main.authors, contains('Gege Akutami'));
      expect(main.japaneseTitles, contains('じゅじゅつかいせん'));
      expect(main.canonicalUrl, startsWith('https://mangabaka.org/'));
      expect(main.cover?.url, contains('mangabaka.dev'));
      expect(page.items.map((MangaBakaSeries s) => s.type), contains('novel'));
    });

    test('ホリミヤ: 简介（去 Markdown）/ 年份 / 开始日期 / 评分归一 / 类型', () {
      final MangaBakaSeries s = parseMangaBakaSearch(
        _fixture('mb_search_horimiya.json'),
      ).items.single;
      expect(s.id, 6029);
      expect(s.description, startsWith('A sweet “aww”-inspiring tale'));
      // 结尾的 `*Source: Yen Press, Vol. 1*` 去掉强调星号、保留段落。
      expect(s.description, endsWith('person!\n\nSource: Yen Press, Vol. 1'));
      expect(s.description, isNot(contains('*')));
      expect(s.year, 2011);
      expect(s.startDate, '2011-10-18');
      expect(s.rating, closeTo(8.35, 0.01));
      expect(s.genres, contains('slice_of_life'));
    });

    test('没有简介 / 评分 / 类型的旧响应字段为空', () {
      final MangaBakaSeries main = parseMangaBakaSearch(
        _fixture('mb_search_jujutsu.json'),
      ).items[1];
      expect(main.description, isNull);
      expect(main.rating, isNull);
      expect(main.startDate, isNull);
      expect(main.genres, isEmpty);
      expect(main.year, 2018);
    });

    test('citrus: erotica 分级记为成人向', () {
      final List<MangaBakaSeries> items = parseMangaBakaSearch(
        _fixture('mb_search_citrus.json'),
      ).items;
      final MangaBakaSeries citrus = items.firstWhere(
        (MangaBakaSeries s) => s.id == 8940,
      );
      expect(citrus.contentRating, 'erotica');
      expect(citrus.isAdult, isTrue);
      expect(items.first.nativeTitle, 'citrus+');
      expect(items.first.isAdult, isFalse);
    });

    test('解不开的 JSON 抛 MangaBakaFormatException', () {
      expect(
        () => parseMangaBakaSearch('<html>'),
        throwsA(isA<MangaBakaFormatException>()),
      );
    });

    test('merged 状态与 merged_with', () {
      final MangaBakaSeries? s = MangaBakaSeries.fromJson(<String, Object?>{
        'id': 1,
        'state': 'merged',
        'merged_with': 6199,
        'type': 'manga',
      });
      expect(s!.isMerged, isTrue);
      expect(s.mergedWith, 6199);
    });
  });

  group('parseMangaBakaSeries', () {
    test('按 id 取的 {status, data} 形状', () {
      final MangaBakaSeries? s = parseMangaBakaSeries(
        _fixture('mb_series_8940.json'),
      );
      expect(s!.id, 8940);
      expect(s.nativeTitle, 'citrus');
    });
  });

  group('parseMangaBakaImagesPage', () {
    test('やがて君になる: 默认 limit=24 的第一页带 next，类型 / 语言 / 宽高齐全', () {
      final MangaBakaPage<MangaBakaImage> page = parseMangaBakaImagesPage(
        _fixture('mb_images_yagakimi_p1.json'),
      );
      expect(page.items.length, 24);
      expect(page.count, 57);
      expect(page.next, contains('page=2'));
      final MangaBakaImage ja1 = page.items.firstWhere(
        (MangaBakaImage i) =>
            i.type == 'volume' && i.language == 'ja' && i.index == '1',
      );
      expect(ja1.indexNumeric, 1);
      expect(ja1.raw.width, 1800);
      expect(ja1.raw.height, 2560);
      expect(ja1.raw.format, 'jpeg');
      expect(
        page.items.where((MangaBakaImage i) => i.type == 'banner'),
        hasLength(1),
      );
      expect(
        page.items.where((MangaBakaImage i) => i.contentRating == 'suggestive'),
        isNotEmpty,
      );
    });

    test('ONE PIECE: limit=50 第一页 50 条，next 保留筛选参数', () {
      final MangaBakaPage<MangaBakaImage> page = parseMangaBakaImagesPage(
        _fixture('mb_images_onepiece_p1.json'),
      );
      expect(page.items.length, 50);
      expect(page.count, 115);
      expect(page.next, contains('type=volume'));
      expect(page.next, contains('language=ja'));
      expect(page.next, contains('page=2'));
    });

    test('小数卷号：index 字符串与 index_numeric', () {
      final MangaBakaImage? image = MangaBakaImage.fromJson(<String, Object?>{
        'id': 9,
        'index': '28.5',
        'type': 'volume',
        'language': 'ja',
        'image': <String, Object?>{
          'raw': <String, Object?>{'url': 'https://x/y', 'width': 10},
        },
      });
      expect(image!.index, '28.5');
      expect(image.indexNumeric, 28.5);
    });
  });

  group('mangaBakaPlainText', () {
    test('去链接 / 图片 / 粗体 / 斜体 / 标题 / 代码，保留段落', () {
      expect(
        mangaBakaPlainText(
          '## Story\n\n**Hori** meets [Miyamura](https://x.y/z) ![c](https://i)'
          '\n\n\n\n_Source: `Yen Press`_',
        ),
        'Story\n\nHori meets Miyamura\n\nSource: Yen Press',
      );
    });

    test('词内下划线与单个星号不动；全是标记时为 null', () {
      expect(mangaBakaPlainText('slice_of_life 5 * 3'), 'slice_of_life 5 * 3');
      expect(mangaBakaPlainText('![](https://i)'), isNull);
    });
  });

  test('mangaBakaGenreLabel: 蛇形键转展示名', () {
    expect(mangaBakaGenreLabel('slice_of_life'), 'Slice of life');
    expect(mangaBakaGenreLabel('romance'), 'Romance');
  });
}
