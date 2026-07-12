import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/collections/shelf_sort.dart';

/// 排序交互重设计层次 A：排序模式纯函数（naturalCompare + compareShelfSortKeys）。
ShelfSortKey _key({
  int recentScore = 0,
  String title = '',
  int importedAt = 0,
  String tieKey = '',
}) =>
    ShelfSortKey(
      recentScore: recentScore,
      title: title,
      importedAt: importedAt,
      tieKey: tieKey,
    );

void main() {
  group('naturalCompare', () {
    test('数字段按数值比较：卷1 < 卷2 < 卷10', () {
      expect(naturalCompare('第1卷', '第2卷'), lessThan(0));
      expect(naturalCompare('第2卷', '第10卷'), lessThan(0));
      expect(naturalCompare('第10卷', '第9卷'), greaterThan(0));
    });

    test('前导零按数值等值，靠原文兜底确定性', () {
      expect(naturalCompare('ep01', 'ep1'), isNot(0), reason: '全序必须可定');
      expect(naturalCompare('ep01', 'ep2'), lessThan(0));
      expect(naturalCompare('ep010', 'ep9'), greaterThan(0));
    });

    test('超长数字段不溢出（先长度后逐位）', () {
      expect(
        naturalCompare('a99999999999999999999', 'a100000000000000000000'),
        lessThan(0),
      );
    });

    test('ASCII 不分大小写；完全相同返回 0', () {
      expect(naturalCompare('Abc', 'abC'), isNot(0), reason: '大小写全等兜底原文');
      expect(naturalCompare('abc', 'abd'), lessThan(0));
      expect(naturalCompare('ABC', 'abd'), lessThan(0));
      expect(naturalCompare('same', 'same'), 0);
    });

    test('前缀更短者在前', () {
      expect(naturalCompare('abc', 'abcd'), lessThan(0));
      expect(naturalCompare('第2卷·特典', '第2卷'), greaterThan(0));
    });
  });

  group('compareShelfSortKeys', () {
    test('recent：recentScore 大者在前，退 importedAt，再退名称', () {
      expect(
        compareShelfSortKeys(
          _key(recentScore: 200),
          _key(recentScore: 100),
          ShelfSortMode.recent,
        ),
        lessThan(0),
      );
      expect(
        compareShelfSortKeys(
          _key(recentScore: 100, importedAt: 5),
          _key(recentScore: 100, importedAt: 9),
          ShelfSortMode.recent,
        ),
        greaterThan(0),
      );
      expect(
        compareShelfSortKeys(
          _key(title: 'a'),
          _key(title: 'b'),
          ShelfSortMode.recent,
        ),
        lessThan(0),
      );
    });

    test('title：natural 序，同名退 importedAt 新者在前', () {
      expect(
        compareShelfSortKeys(
          _key(title: '第2卷'),
          _key(title: '第10卷'),
          ShelfSortMode.title,
        ),
        lessThan(0),
      );
      expect(
        compareShelfSortKeys(
          _key(title: 'x', importedAt: 9),
          _key(title: 'x', importedAt: 5),
          ShelfSortMode.title,
        ),
        lessThan(0),
      );
    });

    test('imported：新导入在前，同刻退名称', () {
      expect(
        compareShelfSortKeys(
          _key(importedAt: 9),
          _key(importedAt: 5),
          ShelfSortMode.imported,
        ),
        lessThan(0),
      );
      expect(
        compareShelfSortKeys(
          _key(importedAt: 5, title: 'a'),
          _key(importedAt: 5, title: 'b'),
          ShelfSortMode.imported,
        ),
        lessThan(0),
      );
    });

    test('全键相等靠 tieKey 决出稳定全序', () {
      for (final ShelfSortMode mode in ShelfSortMode.values) {
        expect(
          compareShelfSortKeys(_key(tieKey: 'a'), _key(tieKey: 'b'), mode),
          lessThan(0),
        );
        expect(
          compareShelfSortKeys(_key(tieKey: 'a'), _key(tieKey: 'a'), mode),
          0,
        );
      }
    });
  });

  group('ShelfSortMode.fromName', () {
    test('已知名解析，未知/旧残留退默认 recent', () {
      expect(ShelfSortMode.fromName('title'), ShelfSortMode.title);
      expect(ShelfSortMode.fromName('imported'), ShelfSortMode.imported);
      expect(ShelfSortMode.fromName('recent'), ShelfSortMode.recent);
      expect(ShelfSortMode.fromName('bogus'), ShelfSortMode.recent);
      expect(ShelfSortMode.fromName(''), ShelfSortMode.recent);
    });
  });
}
