import 'package:fushi_engine/media/metadata/books/book_search_query.dart';
import 'package:test/test.dart';

/// BUG-5395：书架单卷名 → 在线源搜索词。实测（2026-11-23）：MangaBaka 对带卷号 /
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

  group('主标题（去副标题）', () {
    test('全角分隔符随处切；中日文书名按第一个空白切', () {
      expect(bookTitleMainPart('テスト漫画：ブルー'), 'テスト漫画');
      expect(bookTitleMainPart('ワンパンマン ～外伝～'), 'ワンパンマン');
      expect(bookTitleMainPart('ソードアート・オンライン プログレッシブ'), 'ソードアート・オンライン');
      expect(bookTitleMainPart('Spice and Wolf: Spring Log'), 'Spice and Wolf');
    });

    test('半角 - ~ : 两边都是中日韩字时也算分隔（文件名常见写法）', () {
      expect(bookTitleMainPart('ワンパンマン~外伝~'), 'ワンパンマン');
      expect(bookTitleMainPart('三体-黑暗森林'), '三体');
      expect(bookTitleMainPart('テスト漫画:ブルー'), 'テスト漫画');
      expect(bookTitleMainPart('テスト漫画－ブルー'), 'テスト漫画');
      expect(bookTitleMainPart('Re:ゼロから始める異世界生活 ~外伝~'), 'Re:ゼロから始める異世界生活');
    });

    test('切不出像样的主标题时 null', () {
      expect(bookTitleMainPart('One Piece'), isNull);
      expect(bookTitleMainPart('Spider-Man'), isNull);
      expect(bookTitleMainPart('Re:ゼロから始める異世界生活'), isNull);
      expect(bookTitleMainPart('86―エイティシックス―'), isNull);
      expect(bookTitleMainPart('나 혼자만 레벨업'), isNull);
      expect(bookTitleMainPart('ホリミヤ'), isNull);
    });

    test('系列级最后试主标题；单卷级在「名」之后试', () {
      expect(series('テスト漫画：ブルー 第2巻'), <String>['テスト漫画：ブルー', 'テスト漫画']);
      expect(volume('テスト漫画：ブルー 第2巻'), <String>[
        'テスト漫画：ブルー 第2巻',
        'テスト漫画：ブルー 2',
        'テスト漫画：ブルー',
        'テスト漫画',
      ]);
    });

    test('bookSeriesSearchQueries：输入已是系列名，不再去卷号', () {
      expect(bookSeriesSearchQueries('Steins;Gate 0'), <String>[
        'Steins;Gate 0',
      ]);
      expect(bookSeriesSearchQueries('Spider-Man 2099'), <String>[
        'Spider-Man 2099',
      ]);
      expect(bookSeriesSearchQueries('テスト漫画：ブルー'), series('テスト漫画：ブルー 第2巻'));
    });

    test('bookSearchSeriesTitle：去标签与卷号', () {
      expect(bookSearchSeriesTitle('[川原礫] ソードアート・オンライン 01'), 'ソードアート・オンライン');
      expect(bookSearchSeriesTitle('[Comic][进击的巨人][諫山創] Vol.01'), '进击的巨人');
      expect(bookSearchSeriesTitle('ホリミヤ'), 'ホリミヤ');
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
