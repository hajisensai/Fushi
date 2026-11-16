import 'package:test/test.dart';
import 'package:fushi/src/media/metadata/scrape_title_matcher.dart';

void main() {
  test('唯一精确标题在全半角、大小写和装饰符归一化后自动命中', () {
    final String? match = uniqueExactScrapeTitleMatch<String>(
      query: 'Ｔｅｎｓｅｉ－Ｏｕｊｏ',
      candidates: const <String>['other', 'tensei oujo'],
      titles: (String candidate) => <String>[candidate],
      sourceOf: (String candidate) => 'same-source',
    );

    expect(match, 'tensei oujo');
  });

  test('同一个源里同名多结果保持待确认，不擅自取第一条', () {
    final String? match = uniqueExactScrapeTitleMatch<String>(
      query: '同名作品',
      candidates: const <String>['同名作品', '同名作品'],
      titles: (String candidate) => <String>[candidate],
      sourceOf: (String candidate) => 'same-source',
    );

    expect(match, isNull);
  });

  test('近似标题不自动应用', () {
    final String? match = uniqueExactScrapeTitleMatch<String>(
      query: '标准标题',
      candidates: const <String>['标准标题 第二季'],
      titles: (String candidate) => <String>[candidate],
      sourceOf: (String candidate) => 'same-source',
    );

    expect(match, isNull);
  });

  test('不同源各一条同名是同一部作品：按候选顺序取第一个源的命中', () {
    final ({String source, String title})? match =
        uniqueExactScrapeTitleMatch<({String source, String title})>(
          query: 'ATRI -My Dear Moments-',
          candidates: const <({String source, String title})>[
            (source: 'bangumi', title: 'ATRI -My Dear Moments-'),
            (source: 'bangumi', title: 'ATRI 原声集'),
            (source: 'vndb', title: 'ATRI -My Dear Moments-'),
          ],
          titles: (({String source, String title}) c) => <String>[c.title],
          sourceOf: (({String source, String title}) c) => c.source,
        );

    expect(match, (source: 'bangumi', title: 'ATRI -My Dear Moments-'));
  });

  test('任一源内同名多结果即为真歧义，别的源唯一也不自动采用', () {
    final ({String source, String title})? match =
        uniqueExactScrapeTitleMatch<({String source, String title})>(
          query: '同名作品',
          candidates: const <({String source, String title})>[
            (source: 'bangumi', title: '同名作品'),
            (source: 'vndb', title: '同名作品'),
            (source: 'vndb', title: '同名作品'),
          ],
          titles: (({String source, String title}) c) => <String>[c.title],
          sourceOf: (({String source, String title}) c) => c.source,
        );

    expect(match, isNull);
  });
}
