import 'dart:io';

import 'package:fushi_engine/media/metadata/book_art/bangumi_tankobon.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart';
import 'package:test/test.dart';

String _fixture(String name) =>
    File('test/fixtures/mangabaka/$name').readAsStringSync();

void main() {
  group('bangumiTankobonVolume', () {
    final List<(String, String, num?)> cases = <(String, String, num?)>[
      ('ONE PIECE (1)', 'ONE PIECE', 1),
      ('惑星のさみだれ (01)', '惑星のさみだれ', 1),
      ('キノの旅 XIV -the Beautiful World-', 'キノの旅', 14),
      ('キノの旅 XIV -the Beautiful World-', 'キノの旅 -the Beautiful World-', 14),
      ('ソードアート・オンライン (5) ファントム・バレット', 'ソードアート・オンライン', 5),
      ('呪術廻戦 (0) 東京都立呪術高等専門学校', '呪術廻戦', 0),
      ('ONE PIECE (10)', 'ONE PIECE (1', 10),
      ('涼宮ハルヒの憂鬱 第3巻', '涼宮ハルヒの憂鬱', 3),
      ('ＯＮＥ ＰＩＥＣＥ （２）', 'ONE PIECE', 2),
      ('86―エイティシックス―Ep.2〈上〉', '86―エイティシックス―', null),
      ('本好きの下剋上 第一部「兵士の娘I」', '本好きの下剋上', null),
      ('やがて君になる 公式コミックアンソロジー', 'やがて君になる', null),
    ];
    for (final (String name, String series, num? expected) in cases) {
      test('$name ← $series = $expected', () {
        expect(bangumiTankobonVolume(name, seriesName: series), expected);
      });
    }
  });

  test('搜索结果系列条目排前（同序稳定），作者取 infobox 日文名', () {
    final List<BangumiBookSubject> found = parseBangumiBookSearch(
      _fixture('bgm_search_yagakimi.json'),
    );
    expect(found.first.id, 132936);
    expect(found.first.isSeries, isTrue);
    expect(found.first.authors, contains('仲谷鳰'));
    expect(found.first.toCandidate().kind, BookArtCandidateKind.manga);
    final List<BangumiBookSubject> reordered = parseBangumiBookSearch(
      '{"data":[{"id":2,"name":"涼宮ハルヒの憂鬱","series":false},'
      '{"id":1,"name":"涼宮ハルヒ","series":true},'
      '{"id":3,"name":"x","series":false}]}',
    );
    expect(reordered.map((BangumiBookSubject s) => s.id), <int>[1, 2, 3]);
  });

  test('单行本关联：只取 relation=单行本、卷号认得出、有封面的条目', () {
    final List<BangumiTankobon> vols = parseBangumiTankobons(
      _fixture('bgm_relations_132936.json'),
      seriesName: 'やがて君になる',
    );
    expect(vols.map((BangumiTankobon t) => t.volume), <num>[
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
    ]);
    expect(vols.first.coverUrl, startsWith('https://lain.bgm.tv/pic/cover/l/'));
  });

  test('缩放段去掉成原图', () {
    expect(
      bangumiOriginalImageUrl('https://lain.bgm.tv/r/400/pic/cover/l/a/b.jpg'),
      'https://lain.bgm.tv/pic/cover/l/a/b.jpg',
    );
  });
}
