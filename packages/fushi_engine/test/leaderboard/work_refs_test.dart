import 'package:fushi_engine/leaderboard/work_refs.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeWorkTitleKey', () {
    test('全角 ASCII 与全角空格转半角、小写、去空白', () {
      expect(normalizeWorkTitleKey('ＳＷＯＲＤ　Ａｒｔ Online １'), 'swordartonline1');
      expect(normalizeWorkTitleKey('  Re:ゼロから 始める  '), 're:ゼロから始める');
    });

    test('去掉末尾文库名括号（全角 / 半角）与【】后缀，可叠加', () {
      expect(normalizeWorkTitleKey('キノの旅（電撃文庫）'), 'キノの旅');
      expect(normalizeWorkTitleKey('キノの旅 (電撃文庫)'), 'キノの旅');
      expect(normalizeWorkTitleKey('本好きの下剋上【電子書籍限定特典付き】'), '本好きの下剋上');
      expect(normalizeWorkTitleKey('X【特典】（角川スニーカー文庫）'), 'x');
      // 非文库的括号是标题的一部分，保留。
      expect(normalizeWorkTitleKey('涼宮ハルヒ(上)'), '涼宮ハルヒ(上)');
      // 中间的【】不动；整个标题就是括号时不剥成空。
      expect(normalizeWorkTitleKey('【推しの子】1'), '【推しの子】1');
      expect(normalizeWorkTitleKey('【完全版】'), '【完全版】');
    });

    test('控制字符当空白处理', () {
      expect(normalizeWorkTitleKey('a\tb\u0001c'), 'abc');
      expect(normalizeWorkTitleKey('   '), '');
    });
  });

  group('normalizeIsbn13', () {
    test('ISBN-13 带连字符 / 前缀 / 全角数字', () {
      expect(normalizeIsbn13('978-4-04-000001-5'), '9784040000015');
      expect(normalizeIsbn13('urn:isbn:9784040000015'), '9784040000015');
      expect(normalizeIsbn13('ISBN 978-4-04-000001-5'), '9784040000015');
      expect(normalizeIsbn13('９７８４０４０００００１５'), '9784040000015');
    });

    test('ISBN-10（含 X 校验位）转 13 位', () {
      expect(normalizeIsbn13('4-04-000001-3'), '9784040000015');
      expect(normalizeIsbn13('0-8044-2957-X'), '9780804429573');
      expect(normalizeIsbn13('080442957x'), '9780804429573');
    });

    test('校验位错 / 长度错 / 非 978·979 前缀 → null', () {
      expect(normalizeIsbn13('9784040000011'), isNull);
      expect(normalizeIsbn13('4-04-000001-5'), isNull);
      expect(normalizeIsbn13('12345'), isNull);
      expect(normalizeIsbn13('1234567890128'), isNull);
      expect(normalizeIsbn13(''), isNull);
      expect(normalizeIsbn13('abc9784040000011'), isNull);
    });
  });

  group('buildWorkRefs', () {
    test('按优先级输出，每命名空间一个', () {
      expect(
        buildWorkRefs(
          sourceRef: 'plugin:key',
          anidbAid: '123',
          tmdbRef: 'tv:456',
          vndbId: '17',
          isbn: '4-04-000001-3',
          bgmSubjectId: '9',
          title: 'タイトル（電撃文庫）',
          author: '作者 名',
        ),
        <String>[
          'bgm:9',
          'isbn:9784040000015',
          'vndb:v17',
          'tmdb:tv:456',
          'anidb:123',
          'src:plugin:key',
          't:タイトル|作者名',
        ],
      );
    });

    test('无效 ISBN / 空值被丢弃；vndb 已带 v 不重复加', () {
      expect(
        buildWorkRefs(
          isbn: '9784040000012',
          vndbId: 'V5',
          bgmSubjectId: '  ',
          title: 'A',
        ),
        <String>['vndb:v5', 't:a|'],
      );
    });

    test('标题归一化后为空则不产 t', () {
      expect(buildWorkRefs(title: '   '), isEmpty);
      expect(buildWorkRefs(anidbAid: '1', title: ''), <String>['anidb:1']);
    });

    test('超长标题截断后仍满足服务端 256 码元上限，不劈开代理对', () {
      final String longTitle = '𠮷' * 200;
      final List<String> refs = buildWorkRefs(
        title: longTitle,
        author: 'a' * 200,
      );
      final String t = refs.single;
      expect(t.length - 't:'.length, lessThanOrEqualTo(256));
      final String titlePart = t.substring(2, t.indexOf('|'));
      expect(titlePart.runes.every((int r) => r == 0x20bb7), isTrue);
    });
  });
}
