import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/metadata/scrape_title_matcher.dart';

void main() {
  test('唯一精确标题在全半角、大小写和装饰符归一化后自动命中', () {
    final String? match = uniqueExactScrapeTitleMatch<String>(
      query: 'Ｔｅｎｓｅｉ－Ｏｕｊｏ',
      candidates: const <String>['other', 'tensei oujo'],
      titles: (String candidate) => <String>[candidate],
    );

    expect(match, 'tensei oujo');
  });

  test('同名多结果保持待确认，不擅自取第一条', () {
    final String? match = uniqueExactScrapeTitleMatch<String>(
      query: '同名作品',
      candidates: const <String>['同名作品', '同名作品'],
      titles: (String candidate) => <String>[candidate],
    );

    expect(match, isNull);
  });

  test('近似标题不自动应用', () {
    final String? match = uniqueExactScrapeTitleMatch<String>(
      query: '标准标题',
      candidates: const <String>['标准标题 第二季'],
      titles: (String candidate) => <String>[candidate],
    );

    expect(match, isNull);
  });
}
