import 'package:fushi_engine/media/metadata/books/book_search_query.dart';
import 'package:test/test.dart';

/// BUG-5372：书架单卷名 → 在线源搜索词。实测（2026-11-23）：MangaBaka 对带卷号 /
/// 中英混写的词零结果，Bangumi 对混写名零结果，拆开后都能命中。
void main() {
  List<String> series(String q) =>
      bookSearchQueries(q, granularity: BookSearchGranularity.series);
  List<String> volume(String q) =>
      bookSearchQueries(q, granularity: BookSearchGranularity.volume);

  group('系列级（MangaBaka / AniList）', () {
    test('日文 / 中文简繁 / 韩文卷号都去掉', () {
      expect(series('ホリミヤ 第01巻'), <String>['ホリミヤ']);
      expect(series('堀与宫村 第01卷'), <String>['堀与宫村']);
      expect(series('進擊的巨人 第1冊'), <String>['進擊的巨人']);
      expect(series('龍珠 第1集'), <String>['龍珠']);
      expect(series('나 혼자만 레벨업 1권'), <String>['나 혼자만 레벨업']);
      expect(series('一人之下 Vol.1'), <String>['一人之下']);
    });

    test('混写名：整名 → 中日韩部分 → 拉丁部分', () {
      expect(series('Horimiya ホリミヤ 第01巻'), <String>[
        'Horimiya ホリミヤ',
        'ホリミヤ',
        'Horimiya',
      ]);
      expect(series('Solo Leveling 我独自升级 第1卷'), <String>[
        'Solo Leveling 我独自升级',
        '我独自升级',
        'Solo Leveling',
      ]);
      expect(series('Solo Leveling 나 혼자만 레벨업 1권'), <String>[
        'Solo Leveling 나 혼자만 레벨업',
        '나 혼자만 레벨업',
        'Solo Leveling',
      ]);
    });

    test('按话发布：去掉话号', () {
      expect(series('斗罗大陆 第1话'), <String>['斗罗大陆']);
    });

    test('一个词里两种文字的书名不切开', () {
      expect(series('Re:ゼロから始める異世界生活 1'), <String>['Re:ゼロから始める異世界生活']);
      expect(series('SPY×FAMILY 12'), <String>['SPY×FAMILY']);
    });

    test('本来就是系列名：原样一个', () {
      expect(series('Horimiya'), <String>['Horimiya']);
      expect(series('  ホリミヤ  '), <String>['ホリミヤ']);
      expect(series(''), isEmpty);
    });
  });

  group('单卷级（Bangumi / NDL / 楽天）', () {
    test('原词优先，再「名 卷号」、名', () {
      expect(volume('ホリミヤ 第01巻'), <String>['ホリミヤ 第01巻', 'ホリミヤ 1', 'ホリミヤ']);
      expect(volume('龍珠 第1集'), <String>['龍珠 第1集', '龍珠 1', '龍珠']);
    });

    test('混写名的「名」取中日韩部分，最后补拉丁部分；至多 4 个', () {
      expect(volume('Horimiya ホリミヤ 第01巻'), <String>[
        'Horimiya ホリミヤ 第01巻',
        'ホリミヤ 1',
        'ホリミヤ',
        'Horimiya',
      ]);
      expect(
        volume('Solo Leveling 我独自升级 第1卷').length,
        lessThanOrEqualTo(kBookSearchMaxQueries),
      );
    });

    test('小数卷号照写', () {
      expect(volume('ホリミヤ 第10.5巻').elementAt(1), 'ホリミヤ 10.5');
    });
  });

  group('打头标签', () {
    test('作者 / 分类标签去掉', () {
      expect(series('[川原礫] ソードアート・オンライン 01'), <String>['ソードアート・オンライン']);
      expect(series('【漫画】进击的巨人 第01卷'), <String>['进击的巨人']);
    });

    test('整个书名都在括号里：取含中日韩字的那组，卷号照读', () {
      expect(series('[Comic][进击的巨人][諫山創] Vol.01'), <String>['进击的巨人']);
      expect(parseBookSearchSeries('[Comic][进击的巨人][諫山創] Vol.01')?.volume, 1);
    });

    test('去完什么都不剩时原样返回', () {
      expect(stripLeadingBookTags('[進撃の巨人]'), '[進撃の巨人]');
    });
  });

  group('splitBookTitleScripts', () {
    test('只有两种文字都在时才拆', () {
      expect(splitBookTitleScripts('ONE PIECE ワンピース'), (
        cjk: 'ワンピース',
        latin: 'ONE PIECE',
      ));
      expect(splitBookTitleScripts('ホリミヤ'), isNull);
      expect(splitBookTitleScripts('Horimiya'), isNull);
      expect(splitBookTitleScripts('86 エイティシックス'), isNull);
      expect(splitBookTitleScripts('ホリミヤ 2'), isNull);
    });

    // 书图批量刮削的候选判档（localBookTitleTier）与 Bangumi 查询序列共用这一份拆法。
    test('多词拉丁名整段归拉丁部分', () {
      expect(splitBookTitleScripts('Spy Family スパイファミリー'), (
        cjk: 'スパイファミリー',
        latin: 'Spy Family',
      ));
    });
  });
}
