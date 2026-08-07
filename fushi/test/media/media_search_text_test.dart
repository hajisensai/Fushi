import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/mining/galgame_library_query.dart'
    show normalizeGalgameSearchText;

/// P5-A：书架 / 视频 / 游戏三个库页共用的搜索归一化与匹配。
///
/// 这套实现原本只长在游戏库页；补书架与视频搜索时上提到媒体层，游戏侧改委托。
/// 本测试锁住两件事：① 归一化语义（全角 / 片假名 / 标点折叠）；② 游戏侧委托后
/// 与共享实现**逐字符一致**（防有人日后改一边忘另一边）。
void main() {
  group('normalizeMediaSearchText', () {
    test('全角 ASCII 折成半角、大写折成小写', () {
      expect(normalizeMediaSearchText('ＦＡＴＥ'), 'fate');
      expect(normalizeMediaSearchText('Fate'), 'fate');
    });

    test('片假名折成平假名（基本区）', () {
      expect(normalizeMediaSearchText('カタカナ'), 'かたかな');
      // 已经是平假名的保持不变。
      expect(normalizeMediaSearchText('かたかな'), 'かたかな');
    });

    test('空白与常见标点被丢弃（含全角空格、中点、长音符）', () {
      expect(normalizeMediaSearchText('fate stay night'), 'fatestaynight');
      expect(normalizeMediaSearchText('Fate／stay night'), 'fatestaynight');
      expect(normalizeMediaSearchText('ＦＡＴＥ・ｓｔａｙ'), 'fatestay');
      expect(normalizeMediaSearchText('　全角空格'), '全角空格');
      expect(normalizeMediaSearchText('ラーメン'), 'らめん'); // 长音符丢弃
    });

    test('空串返回空串（不抛）', () {
      expect(normalizeMediaSearchText(''), '');
    });
  });

  group('matchesMediaSearch', () {
    test('空查询恒命中（搜索框为空 = 不过滤）', () {
      expect(
        matchesMediaSearch(query: '', titles: <String>['任意']),
        isTrue,
      );
      // 纯标点的查询归一化后为空，同样视作不过滤。
      expect(
        matchesMediaSearch(query: '・・・', titles: <String>['任意']),
        isTrue,
      );
    });

    test('排版差异不挡命中：全角/片假名/中点/空格', () {
      const List<String> titles = <String>['Fate／stay night'];
      for (final String q in <String>[
        'fate stay night',
        'ＦＡＴＥ・ｓｔａｙ',
        'staynight',
        'FATE',
      ]) {
        expect(matchesMediaSearch(query: q, titles: titles), isTrue,
            reason: '「$q」应命中 Fate／stay night');
      }
    });

    test('多标题任一命中即算命中（记得住哪个名字是随机的）', () {
      const List<String> titles = <String>['原名カタカナ', '改过的显示名'];
      expect(matchesMediaSearch(query: 'かたかな', titles: titles), isTrue);
      expect(matchesMediaSearch(query: '显示名', titles: titles), isTrue);
    });

    test('真不匹配时返回 false（不是恒真）', () {
      expect(
        matchesMediaSearch(query: 'zzz不存在', titles: <String>['Fate']),
        isFalse,
      );
    });

    test('空标题列表：非空查询不命中', () {
      expect(
        matchesMediaSearch(query: 'fate', titles: const <String>[]),
        isFalse,
      );
    });
  });

  group('filterByMediaSearch（G6：泛型列表筛选，三个漏网搜索框共用）', () {
    test('空/纯空白查询原样返回（同一 List 实例，不重建）', () {
      final List<String> items = <String>['a', 'b'];
      expect(
          identical(filterByMediaSearch(items, '', (String s) => [s]), items),
          isTrue);
      expect(
          identical(
              filterByMediaSearch(items, ' 　 ', (String s) => [s]), items),
          isTrue);
    });

    test('按归一化口径过滤：片假名/全角差异不挡命中', () {
      final List<String> items = <String>['フェイト', 'ＦＡＴＥ', 'unrelated'];
      expect(filterByMediaSearch(items, 'ふぇいと', (String s) => [s]),
          <String>['フェイト']);
      expect(filterByMediaSearch(items, 'fate', (String s) => [s]),
          <String>['ＦＡＴＥ']);
    });

    test('多标题任一命中即留', () {
      final List<List<String>> items = <List<String>>[
        <String>['原名', 'alias-hit'],
        <String>['原名2', '别名2'],
      ];
      expect(
        filterByMediaSearch(items, 'aliashit', (List<String> t) => t),
        <List<String>>[
          <String>['原名', 'alias-hit'],
        ],
      );
    });
  });

  test('游戏侧 normalizeGalgameSearchText 委托后与共享实现逐字符一致', () {
    for (final String s in <String>[
      'Fate／stay night',
      'ＦＡＴＥ・ｓｔａｙ',
      'カタカナ　テスト',
      'ラーメン',
      '「括弧」〜波ダッシュ…',
      '',
    ]) {
      expect(normalizeGalgameSearchText(s), normalizeMediaSearchText(s),
          reason: '委托必须逐字符一致：$s');
    }
  });
}
