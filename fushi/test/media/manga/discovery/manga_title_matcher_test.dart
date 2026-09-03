import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/discovery/manga_title_matcher.dart';

/// 标题模糊匹配打分器：CJK 与拉丁两条路径都要能把「同作品不同写法」判高分、
/// 「不同作品」判低分——阈值 0.55（`kMangaSourceMatchMinScore`）两侧都得有余量。
void main() {
  group('normalizeMangaTitle', () {
    test('小写化并剥离标点/符号', () {
      expect(
        normalizeMangaTitle("Frieren: Beyond Journey's End"),
        'frieren beyond journey s end',
      );
    });

    test('CJK 保留，中点/括号视作分隔', () {
      expect(normalizeMangaTitle('葬送のフリーレン（1）'), '葬送のフリーレン 1');
    });

    test('空白折叠', () {
      expect(normalizeMangaTitle('  a   b  '), 'a b');
    });
  });

  group('mangaTitleMatchScore', () {
    test('完全一致 = 1.0', () {
      expect(mangaTitleMatchScore('葬送のフリーレン', <String>['葬送のフリーレン']), 1.0);
    });

    test('仅标点/大小写差异视同一致', () {
      expect(
        mangaTitleMatchScore(
          'Frieren - Beyond Journeys End',
          <String>["Frieren: Beyond Journey's End"],
        ),
        greaterThan(0.9),
      );
    });

    test('来源标题拼了卷号仍高于阈值（partial 承担包含语义）', () {
      expect(
        mangaTitleMatchScore('葬送のフリーレン 第1巻', <String>['葬送のフリーレン']),
        greaterThan(0.75),
      );
    });

    test('取多标题中的最高分：native 不像但 english 像', () {
      final double score = mangaTitleMatchScore(
        'Attack on Titan',
        <String>['進撃の巨人', 'Attack on Titan'],
      );
      expect(score, 1.0);
    });

    test('不同作品低于阈值', () {
      expect(
        mangaTitleMatchScore('ワンピース', <String>['葬送のフリーレン']),
        lessThan(0.4),
      );
      expect(
        mangaTitleMatchScore(
            'Berserk', <String>["Frieren: Beyond Journey's End"]),
        lessThan(0.4),
      );
    });

    test('空输入 = 0', () {
      expect(mangaTitleMatchScore('', <String>['x']), 0);
      expect(mangaTitleMatchScore('！？', <String>['x']), 0);
      expect(mangaTitleMatchScore('x', <String>[]), 0);
    });
  });
}
