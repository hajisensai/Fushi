import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_series.dart';
import 'package:fushi_engine/media/collections/book_series_grouper.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/sync/override_title_db.dart';

/// 书架 / 漫画库分卷按系列自动收进合集（用户漫画库「志乃と恋」1–4 卷散成四张卡；
/// 小说「安達としまむら」1–13 卷）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseBookSeriesKey（用户库实际书名）', () {
    test('漫画：CRC 后缀、全角 / 半角卷号、第N巻都归到同一系列', () {
      final Map<String, num?> volumes = <String, num?>{
        '志乃と恋 [3574f94a]': null,
        '志乃と恋 ２ [e11812e5]': 2,
        '志乃と恋 3 [998c5526]': 3,
        '志乃と恋 ４': 4,
        '志乃と恋 第5巻': 5,
        '志乃と恋 Vol.6': 6,
        '志乃と恋（7）': 7,
      };
      volumes.forEach((String title, num? volume) {
        final BookSeriesKey key = parseBookSeriesKey(title)!;
        expect(key.key, '志乃と恋', reason: title);
        expect(key.seriesTitle, '志乃と恋', reason: title);
        expect(key.volume, volume, reason: title);
      });
    });

    // rT5chqFYOK：按话发布的漫画「X 第N話 前編 [hash]」每话各占一张卡。
    test('漫画按话：第N話（可带前編 / 中編 / 後編）归到同一系列，话号不当卷号', () {
      final Map<String, BookEpisodeNumber> episodes =
          <String, BookEpisodeNumber>{
            '十歳の最強魔導師 第1話 前編 [c36675f0]': (number: 1, part: 1),
            '十歳の最強魔導師 第2話 前編 [0af1bc64]': (number: 2, part: 1),
            '十歳の最強魔導師 第12話 前編 [64b6baac]': (number: 12, part: 1),
            '十歳の最強魔導師 第１話 後編': (number: 1, part: 3),
            '十歳の最強魔導師 第3話・中編': (number: 3, part: 2),
            '十歳の最強魔導師第4話': (number: 4, part: 0),
            '十歳の最強魔導師 第5话 后篇': (number: 5, part: 3),
            // 话号后跟出版标签：同卷号判据先剥一层结尾标签再认。
            '十歳の最強魔導師 第6話 前編 (少年マガジン)': (number: 6, part: 1),
            '十歳の最強魔導師 第7話 (少年マガジン) [c36675f0]': (number: 7, part: 0),
          };
      episodes.forEach((String title, BookEpisodeNumber episode) {
        final BookSeriesKey key = parseBookSeriesKey(title)!;
        expect(key.key, '十歳の最強魔導師', reason: title);
        expect(key.seriesTitle, '十歳の最強魔導師', reason: title);
        expect(key.episode, episode, reason: title);
        expect(key.volume, isNull, reason: '第 N 话不是第 N 卷：$title');
      });
      final BookSeriesKey volumed = parseBookSeriesKey('十歳の最強魔導師 第3巻 第12話')!;
      expect(volumed.key, '十歳の最強魔導師');
      expect(volumed.volume, 3);
      expect(volumed.episode, (number: 12, part: 0));
      // 卷号书名不受影响；目录语境里「第1話」仍是章节目录、不是分卷。
      expect(parseBookSeriesKey('志乃と恋 第5巻')!.episode, isNull);
      expect(
        parseBookVolumeFolderName('第1話', seriesFolderName: '十歳の最強魔導師'),
        isNull,
      );
    });

    test('小说：卷号贴在假名后、结尾出版标签、小数卷号', () {
      final Map<String, num?> volumes = <String, num?>{
        '安達としまむら': null,
        '安達としまむら2': 2,
        '安達としまむら10': 10,
        '安達としまむら13 (電撃文庫)': 13,
        '安達としまむら99.9': 99.9,
      };
      volumes.forEach((String title, num? volume) {
        final BookSeriesKey key = parseBookSeriesKey(title)!;
        expect(key.key, '安達としまむら', reason: title);
        expect(key.volume, volume, reason: title);
      });
      expect(
        parseBookSeriesKey('安達としまむらSS')!.key,
        isNot('安達としまむら'),
        reason: '番外 SS 不是卷号，不猜',
      );
    });

    // n4KC1azJvw：日文轻小说「各卷副标题 + 结尾 <系列名>」以前把系列名当出版标签
    // 丢掉，整套散在书架上。
    test('结尾标签是正文前缀时就是系列名（青ブタ形态）', () {
      const List<String> titles = <String>[
        '青春ブタ野郎はバニーガール先輩の夢を見ない<青春ブタ野郎>',
        '青春ブタ野郎はプチデビル後輩の夢を見ない<青春ブタ野郎>',
        '青春ブタ野郎はロジカルウィッチの夢を見ない <青春ブタ野郎>',
      ];
      for (final String title in titles) {
        final BookSeriesKey key = parseBookSeriesKey(title)!;
        expect(key.key, '青春ブタ野郎', reason: title);
        expect(key.seriesTitle, '青春ブタ野郎', reason: title);
        expect(key.volume, isNull, reason: title);
      }
      expect(sharedBookSeriesKey(titles), '青春ブタ野郎');
      final BookSeriesKey numbered = parseBookSeriesKey(
        'とある魔術の禁書目録 3（とある魔術の禁書目録）',
      )!;
      expect(numbered.key, 'とある魔術の禁書目録');
      expect(numbered.seriesTitle, 'とある魔術の禁書目録');
      expect(numbered.volume, 3, reason: '正文末尾的卷号照常读');
    });

    test('不是正文前缀的结尾标签仍按出版标签处理，不拿来归组', () {
      // 同一文库的不同作品共享 (電撃文庫)，不能因此并成一组。
      expect(
        parseBookSeriesKey('とらドラ! (電撃文庫)')!.key,
        isNot(parseBookSeriesKey('灼眼のシャナ (電撃文庫)')!.key),
      );
      expect(parseBookSeriesKey('とらドラ! (電撃文庫)')!.key, 'とらドラ!');
      // 单字标签碰巧是正文首字不算系列名。
      expect(parseBookSeriesKey('上野さんは不器用<上>')!.key, '上野さんは不器用');
      // 标签与正文相同（不是真前缀）走原判据。
      expect(parseBookSeriesKey('安達としまむら (安達としまむら)')!.key, '安達としまむら');
    });

    // 用户书架实报（2026-11-17 截图）：小说「週に一度クラスメイトを買う話」十卷 + 九本
    // BOOK☆WALKER 特典册全部散成单卡——卷号后面跟着副标题、中途换副标题、特典册
    // 整个书名包在『』里，旧的「只认结尾卷号」每卷系列键各不相同。
    test('卷号后跟成对副标题、中途换副标题、无卷号的第 1 卷：同一系列', () {
      final Map<String, num?> volumes = <String, num?>{
        '週に一度クラスメイトを買う話　～ふたりの時間、言い訳の五千円～': null,
        '週に一度クラスメイトを買う話２　～ふたりの時間、言い訳の五千円～': 2,
        '週に一度クラスメイトを買う話４　～ふたりの時間、言い訳の五千円～': 4,
        '週に一度クラスメイトを買う話５　～ふたりの秘密は一つ屋根の下～': 5,
        '週に一度クラスメイトを買う話10　～ふたりの秘密は一つ屋根の下～': 10,
        // 漫画版：副标题在卷号前，卷号后还有出版标签与 CRC。
        '週に一度クラスメイトを買う話 ～ふたりの時間、言い訳の五千円～ 1 '
                '(ヤングチャンピオン・コミックス) [31aa2836]':
            1,
        '週に一度クラスメイトを買う話 ～ふたりの時間、言い訳の五千円～ 2 [e0914585]': 2,
      };
      volumes.forEach((String title, num? volume) {
        final BookSeriesKey key = parseBookSeriesKey(title)!;
        expect(key.key, '週に一度クラスメイトを買う話', reason: title);
        expect(key.seriesTitle, '週に一度クラスメイトを買う話', reason: title);
        expect(key.volume, volume, reason: title);
        expect(key.bonus, isFalse, reason: title);
      });
      // 别的成对定界符；副标题剥到系列名为空就不剥。
      expect(parseBookSeriesKey('百合魔導人形　～夢見る少女のハーレムクエスト～')!.key, '百合魔導人形');
      expect(
        parseBookSeriesKey('魔法少女ノ魔女裁判 クリエイターズアートブック -虚実- [8a0798fd]')!.key,
        parseBookSeriesKey('魔法少女ノ魔女裁判 クリエイターズアートブック -表裏- [e10d3888]')!.key,
      );
      expect(parseBookSeriesKey('～仮題～')!.key, '~仮題~');
      // slug 里的连字符不是副标题定界符。
      expect(
        parseBookSeriesKey('Karakai-Jouzu-Takagi-san')!.key,
        'karakai-jouzu-takagi-san',
      );
    });

    test('『正篇』+ 店铺特典后缀是正篇的特典册：同系列同卷号，排在正篇之后', () {
      const String suffix = 'BOOK☆WALKER限定書き下ろしショートストーリー';
      final BookSeriesKey ss = parseBookSeriesKey(
        '『週に一度クラスメイトを買う話１０　～ふたりの秘密は一つ屋根の下～』$suffix',
      )!;
      expect(ss.key, '週に一度クラスメイトを買う話');
      expect(ss.seriesTitle, '週に一度クラスメイトを買う話');
      expect(ss.volume, 10);
      expect(ss.bonus, isTrue);
      final BookSeriesKey main = parseBookSeriesKey(
        '週に一度クラスメイトを買う話10　～ふたりの秘密は一つ屋根の下～',
      )!;
      expect(compareBookSeriesPosition(main, ss), lessThan(0));
      expect(bookSeriesPosition(main), isNot(bookSeriesPosition(ss)));
      // 无卷号的单本 + 它的特典册：同系列，位置各不相同。
      final BookSeriesKey enman = parseBookSeriesKey('円満家庭の人妻が娘の友達にドはまりする話')!;
      final BookSeriesKey enmanSs = parseBookSeriesKey(
        '『円満家庭の人妻が娘の友達にドはまりする話』$suffix',
      )!;
      expect(enmanSs.key, enman.key);
      expect(enmanSs.bonus, isTrue);
      expect(bookSeriesPosition(enman), isNull);
      expect(bookSeriesPosition(enmanSs), isNotNull);
      // 只是被引号包着（后面没有后缀）不算特典册；引号不闭合按普通书名。
      expect(parseBookSeriesKey('『志乃と恋』 ２')!.bonus, isFalse);
      expect(parseBookSeriesKey('『志乃と恋 ２』')!.volume, 2);
      expect(parseBookSeriesKey('『志乃と恋 ２')!.key, '『志乃と恋');
    });

    test('卷号前后夹着标签：标签不进系列键', () {
      final Map<String, num?> volumes = <String, num?>{
        '魔法少女にあこがれて (2) [6dbad9ae]': 2,
        '魔法少女にあこがれて【電子限定特典付き】 (1) [9fb54b5c]': 1,
        '魔法少女にあこがれて【特典コラボペーパー付き 】 (9) [9e24ed4f]': 9,
        '魔法少女にあこがれて 3【電子限定特典付き】': 3,
        '魔法少女にあこがれて (電撃コミックス) 4 【特装版】': 4,
      };
      volumes.forEach((String title, num? volume) {
        final BookSeriesKey key = parseBookSeriesKey(title)!;
        expect(key.key, '魔法少女にあこがれて', reason: title);
        expect(key.seriesTitle, '魔法少女にあこがれて', reason: title);
        expect(key.volume, volume, reason: title);
      });
      // 整个书名就是一个标签：不剥成空。
      expect(parseBookSeriesKey('(仮)')!.key, '(仮)');
    });

    test('卷号夹在系列名与自由副标题之间', () {
      final Map<String, (String, num)> cases = <String, (String, num)>{
        'ソードアート・オンライン3 フェアリィ・ダンス': ('ソードアート・オンライン', 3),
        'ソードアート・オンライン 4 フェアリィ・ダンス (電撃文庫)': ('ソードアート・オンライン', 4),
        '魔法科高校の劣等生(3) 九校戦編<上>': ('魔法科高校の劣等生', 3),
        'Overlord 3 The Bloody Valkyrie': ('overlord', 3),
      };
      cases.forEach((String title, (String, num) expected) {
        final BookSeriesKey key = parseBookSeriesKey(title)!;
        expect(key.key, expected.$1, reason: title);
        expect(key.volume, expected.$2, reason: title);
      });
      // 反例：书名开头的数字、字母贴数字、数字后不是空白、四位年份 / 型号。
      for (final String title in <String>[
        '3月のライオン 前編',
        '86 エイティシックス',
        'Catch22 Revisited',
        '名探偵コナン 100万ドルの五稜星',
        '機動戦士ガンダム 0083 STARDUST MEMORY',
        'Title 2-02 extra',
      ]) {
        expect(parseBookSeriesKey(title)!.volume, isNull, reason: title);
      }
    });

    test('合集名保留原文写法；书名本身的数字不被当卷号吃掉', () {
      final BookSeriesKey fullWidth = parseBookSeriesKey('Ｒｅ：ゼロ！　１')!;
      expect(fullWidth.volume, 1);
      expect(fullWidth.seriesTitle, 'Ｒｅ：ゼロ！', reason: '合集名保留原文的全角写法，只有比较键折半角');
      expect(fullWidth.key, parseBookSeriesKey('Re:ゼロ! 2')!.key);
      expect(parseBookSeriesKey('86')!.volume, isNull);
      expect(parseBookSeriesKey('86─エイティシックス─')!.volume, isNull);
      expect(parseBookSeriesKey('3月のライオン')!.volume, isNull);
      expect(parseBookSeriesKey('Catch22')!.volume, isNull);
      expect(
        parseBookSeriesKey('志乃と恋 Future')!.key,
        isNot(parseBookSeriesKey('志乃と恋 3')!.key),
      );
    });

    // vECncM6f8Y：mokuro.moe 内置下载的卷名是连字符 slug，`…-02` 以前不认。
    test('连字符 / 下划线卷号：字母后的 `-02` / `_02` 是卷号', () {
      const String takagi =
          'Karakai Jouzu no Takagi-san Karakai-Jouzu-Takagi-san';
      for (final int n in <int>[2, 3, 10]) {
        final String nn = n.toString().padLeft(2, '0');
        final BookSeriesKey key = parseBookSeriesKey('$takagi-$nn')!;
        expect(key.seriesTitle, takagi);
        expect(key.key, takagi.toLowerCase());
        expect(key.volume, n);
      }
      expect(parseBookSeriesKey('One_Piece_101')!.seriesTitle, 'One_Piece');
      expect(parseBookSeriesKey('One_Piece_101')!.volume, 101);
      expect(parseBookSeriesKey('志乃と恋-4')!.key, '志乃と恋');
      expect(parseBookSeriesKey('志乃と恋-4')!.volume, 4);
      // 带连字符但没有卷号的书名不变。
      expect(parseBookSeriesKey('Takagi-san')!.key, 'takagi-san');
      expect(parseBookSeriesKey('Takagi-san')!.volume, isNull);
    });

    test('连字符卷号的反例：字母贴数字、纯数字、数字后的连字符不吃', () {
      expect(parseBookSeriesKey('Catch22')!.volume, isNull);
      expect(parseBookSeriesKey('86')!.volume, isNull);
      expect(parseBookSeriesKey('86-エイティシックス')!.volume, isNull);
      // `2-02` 是编号，不拆成「2」系列的第 2 卷。
      expect(parseBookSeriesKey('Title 2-02')!.volume, isNull);
      // 「Spider-Man 2099」「Spider-Man-2099」会读成第 2099 卷（4 位数字上限内）：
      // 可接受——归组要求同系列 ≥2 卷，单本不建合集（见下方 grouper 用例）。
      expect(parseBookSeriesKey('Spider-Man 2099')!.volume, 2099);
      expect(parseBookSeriesKey('Spider-Man-2099')!.volume, 2099);
      expect(parseBookSeriesKey('Spider-Man-2099')!.seriesTitle, 'Spider-Man');
      // 5 位数字不是卷号。
      expect(parseBookSeriesKey('Area-51234')!.volume, isNull);
    });

    // vECncM6f8Y 后续拍板：自动合集名里的网址 slug 规整成可读名。
    test('readableSeriesTitle：系列名后挂着的自身 slug 去掉，整串 slug 换空格', () {
      expect(
        readableSeriesTitle(
          'Karakai Jouzu no Takagi-san Karakai-Jouzu-Takagi-san',
        ),
        'Karakai Jouzu no Takagi-san',
      );
      expect(readableSeriesTitle('one_piece'), 'One Piece');
      expect(readableSeriesTitle('One_Piece'), 'One Piece');
      expect(
        readableSeriesTitle('karakai-jouzu-takagi-san'),
        'Karakai Jouzu Takagi San',
      );
      expect(
        readableSeriesTitle('Karakai-Jouzu-Takagi-san'),
        'Karakai Jouzu Takagi san',
      );
      expect(readableSeriesTitle('  one_piece  '), 'One Piece');
    });

    test('readableSeriesTitle 反例：正常拼写与不相干的尾词不动', () {
      // 只有一个连字符的是正常拼写。
      expect(readableSeriesTitle('Spider-Man'), 'Spider-Man');
      expect(readableSeriesTitle('Takagi-san'), 'Takagi-san');
      // 尾部 slug 的词不全在前缀里：是副标题，不是重复的 slug。
      expect(
        readableSeriesTitle('Karakai Jouzu no Takagi-san Another-Story'),
        'Karakai Jouzu no Takagi-san Another-Story',
      );
      // 日文前缀切不出拉丁词，不动。
      expect(
        readableSeriesTitle('からかい上手の高木さん Takagi-san'),
        'からかい上手の高木さん Takagi-san',
      );
      expect(readableSeriesTitle('志乃と恋'), '志乃と恋');
      expect(readableSeriesTitle('86'), '86');
      expect(readableSeriesTitle('2-0-1'), '2-0-1');
      expect(readableSeriesTitle('ONE PIECE'), 'ONE PIECE');
    });
  });

  // BUG-4904：书店写法「正文 + 卷号<系列名> (文库名)」以前只看最后一个括号
  // `(MF文庫J)`，整串成了系列键，每卷互不相同、导入后不归合集。
  group('parseBookSeriesKey（书店系列注记）', () {
    const String rezero = 'Re：ゼロから始める異世界生活';

    test('用户实报书名：系列名取尖括号里的写法，卷号从正文末尾读', () {
      for (final int n in <int>[1, 2, 13]) {
        final BookSeriesKey key = parseBookSeriesKey(
          '$rezero $n<$rezero> (MF文庫J)',
        )!;
        expect(key.key, 're:ゼロから始める異世界生活');
        expect(key.seriesTitle, rezero, reason: '合集名保留原文全角冒号');
        expect(key.volume, n);
      }
      expect(
        sharedBookSeriesKey(<String>[
          '$rezero 1<$rezero> (MF文庫J)',
          '$rezero 2<$rezero> (MF文庫J)',
          '$rezero 3<$rezero>',
        ]),
        're:ゼロから始める異世界生活',
      );
    });

    test('与不带注记的普通卷名同键，同一部可以混着归组', () {
      expect(
        parseBookSeriesKey('$rezero 4<$rezero> (MF文庫J)')!.key,
        parseBookSeriesKey('$rezero 5')!.key,
      );
    });

    test('全角括号 / 卷号贴假名 / 外传无卷号 / CRC 后缀', () {
      final BookSeriesKey adachi = parseBookSeriesKey(
        '安達としまむら10＜安達としまむら＞（電撃文庫）',
      )!;
      expect(adachi.key, '安達としまむら');
      expect(adachi.volume, 10);
      final BookSeriesKey ex = parseBookSeriesKey(
        '$rezero Ex 獅子王の見た夢<$rezero> (MF文庫J)',
      )!;
      expect(ex.key, 're:ゼロから始める異世界生活');
      expect(ex.volume, isNull);
      final BookSeriesKey hashed = parseBookSeriesKey(
        '$rezero 6<$rezero> (MF文庫J) [3574f94a]',
      )!;
      expect(hashed.key, 're:ゼロから始める異世界生活');
      expect(hashed.volume, 6);
    });

    test('不是书店注记的写法不误伤', () {
      // 单字分卷标签。
      expect(parseBookSeriesKey('上野さんは不器用<上>')!.key, '上野さんは不器用');
      // 标签不是正文前缀：照旧当出版 / 版本标签，不拿标签当系列名。键与卷号交给
      // 常规文法（BUG-4892 起结尾标签 / 卷号层层剥），注记判据不插手。
      final BookSeriesKey limited = parseBookSeriesKey('タイトル 2<限定版> (電撃文庫)')!;
      expect(limited.key, 'タイトル');
      expect(limited.volume, 2);
      // 尖括号里是别的作品名：不能并进那个系列。
      final BookSeriesKey shana = parseBookSeriesKey('灼眼のシャナ 3<とらドラ!> (電撃文庫)')!;
      expect(shana.key, '灼眼のシャナ');
      expect(shana.key, isNot(parseBookSeriesKey('とらドラ! 1')!.key));
      // 只有文库标签：同文库不同作品不并组。
      expect(
        parseBookSeriesKey('とらドラ! (電撃文庫)')!.key,
        isNot(parseBookSeriesKey('灼眼のシャナ (電撃文庫)')!.key),
      );
    });
  });

  group('BookSeriesGrouper', () {
    late FushiDatabase db;
    late BookSeriesGrouper grouper;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      grouper = BookSeriesGrouper(db);
    });

    tearDown(() => db.close());

    Future<String> addBook(
      String title, {
      String format = 'manga',
      String? sourceMetadata,
      int importedAt = 1000,
    }) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: title,
          title: title,
          epubPath: '/m/$title',
          extractDir: '/m/$title',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: importedAt,
          format: Value<String>(format),
          sourceMetadata: Value<String?>(sourceMetadata),
        ),
      );
      return (await db.resolveEpubBookUid(title))!;
    }

    Future<String> addSrt(String title, {String bookKey = ''}) async {
      final String uid = 'srtbook_$title';
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: uid,
          title: title,
          srtPath: '/s/$title.srt',
          importedAt: 1000,
          bookKey: Value<String>(bookKey),
        ),
      );
      return uid;
    }

    Future<List<String>> members(int collectionId) async {
      final Map<String, String> titleByUid = <String, String>{
        for (final EpubBookRow b in await db.getAllEpubBooks()) b.uid: b.title,
        for (final SrtBookRow s in await db.getAllSrtBooks())
          s.uid: 'srt:${s.title}',
      };
      return <String>[
        for (final MediaCollectionItemRow item in await db.getCollectionItems(
          collectionId,
        ))
          titleByUid[item.entryKey] ?? item.entryKey,
      ];
    }

    // n4KC1azJvw：每卷副标题各不相同、书名里没有系列线索，只有 OPF 声明了系列。
    test('EPUB 声明的系列优先于书名：副标题各异的分卷按声明归组、按卷序排', () async {
      String declared(String name, num index) =>
          encodeEpubSeriesMetadata(EpubSeries(name: name, index: index));
      await addBook(
        'ココロコネクト キズランダム',
        format: 'epub',
        sourceMetadata: declared('ココロコネクト', 2),
      );
      await addBook(
        'ココロコネクト ヒトランダム',
        format: 'epub',
        sourceMetadata: declared('ココロコネクト', 1),
      );
      await addBook(
        'ココロコネクト カコランダム',
        format: 'epub',
        sourceMetadata: declared('ココロコネクト', 3),
      );
      // 读过 OPF、没有声明：照旧走书名启发式，不被并进去。
      await addBook(
        'ココロコネクト アスランダム 上',
        format: 'epub',
        sourceMetadata: encodeEpubSeriesMetadata(null),
      );

      final summary = await grouper.groupAll();

      expect(summary.createdCollectionIds, hasLength(1));
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        summary.createdCollectionIds.single,
      ))!;
      expect(collection.name, 'ココロコネクト');
      expect(await members(collection.id), <String>[
        'ココロコネクト ヒトランダム',
        'ココロコネクト キズランダム',
        'ココロコネクト カコランダム',
      ]);
      // 幂等：再跑一次不新建、不改动。
      final again = await grouper.groupAll();
      expect(again.createdCollectionIds, isEmpty);
    });

    // 用户书架实报（2026-11-17 截图）：这十九本以前是十九张散卡。
    test('副标题各异的正篇 + 『』特典册收进同一个合集，特典册排在同卷正篇之后', () async {
      const String a = '～ふたりの時間、言い訳の五千円～';
      const String b = '～ふたりの秘密は一つ屋根の下～';
      const String ss = 'BOOK☆WALKER限定書き下ろしショートストーリー';
      const String s = '週に一度クラスメイトを買う話';
      final List<String> expected = <String>[
        '$s　$a',
        '$s２　$a',
        '『$s２　$a』$ss',
        '$s３　$a',
        '『$s３　$a』$ss',
        '$s５　$b',
        '『$s５　$b』$ss',
        '${s}10　$b',
        '『$s１０　$b』$ss',
      ];
      // 乱序导入。
      for (final String title in expected.reversed) {
        await addBook(title, format: 'epub');
      }
      await addBook('円満家庭の人妻が娘の友達にドはまりする話', format: 'epub');
      await addBook('『円満家庭の人妻が娘の友達にドはまりする話』$ss', format: 'epub');
      // 同名漫画版在另一个书架，不混进小说合集。
      await addBook('$s $a 1 (ヤングチャンピオン・コミックス) [31aa2836]');
      await addBook('$s $a 2 [e0914585]');

      final summary = await grouper.groupAll();

      final Map<String, List<String>> byName = <String, List<String>>{};
      for (final int id in summary.createdCollectionIds) {
        final String name = (await db.getMediaCollectionById(id))!.name;
        byName.putIfAbsent(name, () => <String>[]).addAll(await members(id));
      }
      expect(byName.keys.toSet(), <String>{s, '円満家庭の人妻が娘の友達にドはまりする話'});
      // 小说与漫画同名：同名 playlist 复用，两个书架各自的卷都在里面；小说卷按卷序、
      // 特典册紧跟同卷正篇。
      final List<String> novels = byName[s]!
          .where((String t) => !t.contains('['))
          .toList();
      expect(novels, expected);
      expect(byName['円満家庭の人妻が娘の友達にドはまりする話'], <String>[
        '円満家庭の人妻が娘の友達にドはまりする話',
        '『円満家庭の人妻が娘の友達にドはまりする話』$ss',
      ]);
      final again = await grouper.groupAll();
      expect(again.createdCollectionIds, isEmpty);
      expect(again.updatedCollectionIds, isEmpty);
    });

    test('卷号前夹着特典标签的卷并进已有系列合集', () async {
      await addBook('魔法少女にあこがれて (2) [6dbad9ae]');
      await addBook('魔法少女にあこがれて (3) [7e9a233f]');
      final int id = (await grouper.groupAll()).createdCollectionIds.single;
      await addBook('魔法少女にあこがれて【電子限定特典付き】 (1) [9fb54b5c]');
      await addBook('魔法少女にあこがれて【特典コラボペーパー付き 】 (9) [9e24ed4f]');

      final summary = await grouper.groupAll();

      expect(summary.createdCollectionIds, isEmpty);
      expect(await members(id), <String>[
        '魔法少女にあこがれて【電子限定特典付き】 (1) [9fb54b5c]',
        '魔法少女にあこがれて (2) [6dbad9ae]',
        '魔法少女にあこがれて (3) [7e9a233f]',
        '魔法少女にあこがれて【特典コラボペーパー付き 】 (9) [9e24ed4f]',
      ]);
    });

    test('漫画四卷叠成一个 playlist 合集，按卷号排；在线漫画与单卷不进', () async {
      await addBook('志乃と恋 ４', importedAt: 1);
      await addBook('志乃と恋 3 [998c5526]', importedAt: 2);
      await addBook('志乃と恋 [3574f94a]', importedAt: 3);
      await addBook('志乃と恋 ２ [e11812e5]', importedAt: 4);
      await addBook('志乃と恋 Future', format: 'epub');
      await addBook(
        '志乃と恋',
        sourceMetadata: '{"type":"hibiki-online-manga","version":3}',
      );
      await addBook('超かぐやメシ!');

      final summary = await grouper.groupAll();

      expect(summary.createdCollectionIds, hasLength(1));
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        summary.createdCollectionIds.single,
      ))!;
      expect(collection.name, '志乃と恋');
      expect(collection.collectionType, 'playlist');
      expect(await members(collection.id), <String>[
        '志乃と恋 [3574f94a]',
        '志乃と恋 ２ [e11812e5]',
        '志乃と恋 3 [998c5526]',
        '志乃と恋 ４',
      ]);
      expect(
        await db.getAllMediaCollections(),
        hasLength(1),
        reason: '单卷作品不建合集',
      );
    });

    test('漫画按话「第N話 前編 [hash]」并成一个合集，按话号 → 分段排；规则卷序能定序', () async {
      final List<String> ordered = <String>[
        '十歳の最強魔導師 第1話 前編 [c36675f0]',
        '十歳の最強魔導師 第1話 後編',
        '十歳の最強魔導師 第2話 前編 [0af1bc64]',
        '十歳の最強魔導師 第10話 前編',
        '十歳の最強魔導師 第12話 前編 [64b6baac]',
      ];
      final Map<String, String> uidByTitle = <String, String>{};
      for (final String t in ordered.reversed) {
        uidByTitle[t] = await addBook(t);
      }

      final summary = await grouper.groupAll();

      expect(summary.createdCollectionIds, hasLength(1));
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        summary.createdCollectionIds.single,
      ))!;
      expect(collection.name, '十歳の最強魔導師');
      expect(await members(collection.id), ordered);

      final BookSeriesOrder order = await BookSeriesOrder.load(db);
      expect(
        order.orderOf(<CollectionMemberKey>[
          for (final String t in ordered.reversed)
            (mediaType: MediaKind.epub.dbValue, entryKey: uidByTitle[t]!),
        ]),
        <CollectionMemberKey>[
          for (final String t in ordered)
            (mediaType: MediaKind.epub.dbValue, entryKey: uidByTitle[t]!),
        ],
      );
    });

    test('小说：EPUB 有声书的 SRT 卡跟同卷 EPUB 一起进合集，纯字幕书自成一卷', () async {
      await addBook('安達としまむら2', format: 'epub');
      await addBook('安達としまむら', format: 'epub');
      await addSrt('安達としまむら', bookKey: '安達としまむら');
      await addSrt('安達としまむら3');

      final int id = (await grouper.groupAll()).createdCollectionIds.single;
      expect(await members(id), <String>[
        '安達としまむら',
        'srt:安達としまむら',
        '安達としまむら2',
        'srt:安達としまむら3',
      ]);
    });

    test('漫画与小说同名系列：够不够建合集按书架分开算', () async {
      await addBook('X 1', format: 'epub');
      await addBook('X 2');
      final summary = await grouper.groupAll();
      expect(
        summary.createdCollectionIds,
        isEmpty,
        reason: '小说 1 卷 + 漫画 1 卷不算同一书架的 2 卷',
      );
    });

    test('新卷补进用户手建的同系列合集（不论名字 / 类型）', () async {
      final int manual = await db.createMediaCollection('安達しま 手动');
      for (final String t in <String>['安達としまむら', '安達としまむら2']) {
        await db.addToCollection(
          manual,
          MediaKind.epub,
          await addBook(t, format: 'epub'),
        );
      }
      await db.reorderCollectionItems(manual, <CollectionMemberKey>[]);
      await addBook('安達としまむら3', format: 'epub');

      final summary = await grouper.groupAll();
      expect(summary.createdCollectionIds, isEmpty);
      expect(summary.updatedCollectionIds, <int>[manual]);
      expect(await members(manual), contains('安達としまむら3'));
    });

    test('只有一卷在主题合集里不会把整套拉进去', () async {
      final int yuri = await db.createMediaCollection('百合');
      await db.addToCollection(yuri, MediaKind.epub, await addBook('志乃と恋 3'));
      await addBook('志乃と恋 1');
      await addBook('志乃と恋 2');

      final int id = (await grouper.groupAll()).createdCollectionIds.single;
      expect(id, isNot(yuri));
      expect(await members(id), <String>['志乃と恋 1', '志乃と恋 2']);
      expect(await members(yuri), <String>['志乃と恋 3']);
    });

    // vECncM6f8Y：mokuro.moe 旧口径入库的两卷（`<系列> <slug>-NN`）以前各自成卡。
    test('mokuro.moe 连字符卷号的两卷归进同一合集，按卷号排；单本 Spider-Man-2099 不建合集', () async {
      const String takagi =
          'Karakai Jouzu no Takagi-san Karakai-Jouzu-Takagi-san';
      await addBook('$takagi-03', importedAt: 1);
      await addBook('$takagi-02', importedAt: 2);
      await addBook('Spider-Man-2099');

      final summary = await grouper.groupAll();

      expect(summary.createdCollectionIds, hasLength(1));
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        summary.createdCollectionIds.single,
      ))!;
      // 合集名去掉了系列名后挂着的 slug（书名 / 归组键不变）。
      expect(collection.name, 'Karakai Jouzu no Takagi-san');
      expect(await members(collection.id), <String>[
        '$takagi-02',
        '$takagi-03',
      ]);
      expect(await db.getAllMediaCollections(), hasLength(1));
    });

    test('规整前按 slug 名建的规则合集改成可读名，来源仍是 rule', () async {
      const String takagi =
          'Karakai Jouzu no Takagi-san Karakai-Jouzu-Takagi-san';
      final int id = await db.createMediaCollection(
        takagi,
        collectionType: 'playlist',
        origin: CollectionOrigin.rule,
      );
      for (final String nn in <String>['02', '03']) {
        await db.addToCollection(
          id,
          MediaKind.epub,
          await addBook('$takagi-$nn'),
          userIntent: false,
        );
      }

      final summary = await grouper.groupAll();

      expect(summary.createdCollectionIds, isEmpty);
      expect(summary.updatedCollectionIds, contains(id));
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        id,
      ))!;
      expect(collection.name, 'Karakai Jouzu no Takagi-san');
      expect(CollectionOrigin.parse(collection.origin), CollectionOrigin.rule);
      expect(await members(id), <String>['$takagi-02', '$takagi-03']);
      expect(await db.getAllMediaCollections(), hasLength(1));

      // 幂等：再跑一次不再改。
      final again = await grouper.groupAll();
      expect(again.updatedCollectionIds, isNot(contains(id)));
    });

    test('用户的合集、可读名已被占用的合集不改名', () async {
      const String takagi =
          'Karakai Jouzu no Takagi-san Karakai-Jouzu-Takagi-san';
      final int user = await db.createMediaCollection(
        takagi,
        collectionType: 'playlist',
      );
      for (final String nn in <String>['02', '03']) {
        await db.addToCollection(
          user,
          MediaKind.epub,
          await addBook('$takagi-$nn'),
          userIntent: false,
        );
      }
      const String other = 'one_piece';
      final int rule = await db.createMediaCollection(
        other,
        collectionType: 'playlist',
        origin: CollectionOrigin.rule,
      );
      final int taken = await db.createMediaCollection(
        'One Piece',
        collectionType: 'playlist',
      );
      for (final String nn in <String>['01', '02']) {
        await db.addToCollection(
          rule,
          MediaKind.epub,
          await addBook('${other}_$nn'),
          userIntent: false,
        );
      }

      await grouper.groupAll();

      expect((await db.getMediaCollectionById(user))!.name, takagi);
      expect((await db.getMediaCollectionById(rule))!.name, other);
      expect((await db.getMediaCollectionById(taken))!.name, 'One Piece');
    });

    // vECncM6f8Y：用户把各卷改名成 `… 2` / `… 3`（显示名覆盖），归组以前只看原名。
    test('改名覆盖后的显示名参与归组，合集名取显示名的系列名', () async {
      await addBook('Takagi raw-a');
      await addBook('Takagi raw-b');
      await adoptOverrideTitleInDb(
        db,
        bookKey: 'Takagi raw-a',
        title: 'Karakai Jouzu no Takagi-san 2',
        updatedAt: 1,
      );
      await adoptOverrideTitleInDb(
        db,
        bookKey: 'Takagi raw-b',
        title: 'Karakai Jouzu no Takagi-san 3',
        updatedAt: 1,
      );

      final summary = await grouper.groupAll();

      expect(summary.createdCollectionIds, hasLength(1));
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        summary.createdCollectionIds.single,
      ))!;
      expect(collection.name, 'Karakai Jouzu no Takagi-san');
      expect(await members(collection.id), <String>[
        'Takagi raw-a',
        'Takagi raw-b',
      ]);
    });

    test('幂等；后来导入的单卷补进已有合集', () async {
      await addBook('志乃と恋 [3574f94a]');
      await addBook('志乃と恋 ２');
      final int id = (await grouper.groupAll()).createdCollectionIds.single;

      final again = await grouper.groupAll();
      expect(again.createdCollectionIds, isEmpty);
      expect(again.updatedCollectionIds, isEmpty);

      await addBook('志乃と恋 3');
      final later = await grouper.groupAll();
      expect(later.updatedCollectionIds, <int>[id]);
      expect(await members(id), <String>[
        '志乃と恋 [3574f94a]',
        '志乃と恋 ２',
        '志乃と恋 3',
      ]);
    });

    // 用户实报：17 卷合集里第 2 卷排在最后，首页续读读完第 2 卷就判整套读完。
    // 书名原样：1、2 卷是全角空格 + 全角数字，3 卷起半角。
    const String dm = '絶対に働きたくないダンジョンマスターが惰眠をむさぼるまで';
    List<String> dmTitles() => <String>[
      '$dm　１',
      '$dm　２',
      for (int n = 3; n <= 17; n++) '$dm $n',
    ];

    test('手动按错序建的系列合集在下次归组时按卷号自愈，且幂等', () async {
      final List<String> titles = dmTitles();
      final Map<String, String> uidByTitle = <String, String>{
        for (final String t in titles) t: await addBook(t, format: 'epub'),
      };
      final int id = await db.createMediaCollection('ダンマス');
      // 手动「建系列」按选择顺序尾插：3..17 在前，1、2 在最后。
      for (final String t in <String>[...titles.skip(2), ...titles.take(2)]) {
        await db.addToCollection(id, MediaKind.epub, uidByTitle[t]!);
      }

      final summary = await grouper.groupAll();
      expect(summary.updatedCollectionIds, <int>[id]);
      expect(await members(id), titles);

      final again = await grouper.groupAll();
      expect(again.updatedCollectionIds, isEmpty, reason: '顺序已对不再写库');
    });

    test('用户手动排过的系列合集不自愈', () async {
      final List<String> titles = dmTitles().take(3).toList();
      final int id = await db.createMediaCollection('ダンマス');
      for (final String t in titles.reversed) {
        await db.addToCollection(
          id,
          MediaKind.epub,
          await addBook(t, format: 'epub'),
        );
      }
      await db.reorderCollectionItems(id, <CollectionMemberKey>[]);

      expect((await grouper.groupAll()).updatedCollectionIds, isEmpty);
      expect(await members(id), titles.reversed.toList());
    });

    // BUG-3923：主系列 + 番外（SS / 外传）的合集以前整张不自愈，阅读器卷 chip 行
    // 照存储的乱序显示。现在主系列各卷在自己占的位置里按卷号排，番外原位不动。
    Future<(int, Map<String, String>)> addCollection(
      String name,
      List<String> titles, {
      String format = 'manga',
    }) async {
      final int id = await db.createMediaCollection(name);
      final Map<String, String> uids = <String, String>{};
      for (final String t in titles) {
        uids[t] = await addBook(t, format: format);
        await db.addToCollection(id, MediaKind.epub, uids[t]!);
      }
      return (id, uids);
    }

    test('主系列 + 番外：主系列按卷号自愈、番外原位，且幂等', () async {
      final (int id, _) = await addCollection('安達としまむら', <String>[
        '安達としまむら5',
        '安達としまむら8',
        '安達としまむら7',
        '安達としまむら6',
        '安達としまむら4',
        '安達としまむら3',
        '安達としまむら2',
        '安達としまむら',
        '安達としまむらSS',
      ], format: 'epub');

      final summary = await grouper.groupAll();
      expect(summary.updatedCollectionIds, <int>[id]);
      expect(await members(id), <String>[
        '安達としまむら',
        '安達としまむら2',
        '安達としまむら3',
        '安達としまむら4',
        '安達としまむら5',
        '安達としまむら6',
        '安達としまむら7',
        '安達としまむら8',
        '安達としまむらSS',
      ]);
      expect(
        (await db.getMediaCollectionById(id))!.orderUpdatedAt,
        0,
        reason: '自愈是自动整理，不冒充用户手动序',
      );

      final again = await grouper.groupAll();
      expect(again.updatedCollectionIds, isEmpty, reason: '顺序已对不再写库');
    });

    test('番外夹在卷之间（AI 已放好）是自愈的不动点：只排主系列，不挪番外', () async {
      final (int id, _) = await addCollection('志乃と恋', <String>[
        '志乃と恋 2',
        '志乃と恋 外伝',
        '志乃と恋 1',
        '志乃と恋 3',
      ]);

      expect((await grouper.groupAll()).updatedCollectionIds, <int>[id]);
      expect(await members(id), <String>[
        '志乃と恋 1',
        '志乃と恋 外伝',
        '志乃と恋 2',
        '志乃と恋 3',
      ], reason: '外伝留在第 2 个位置，主系列 1/2/3 填其余位置');

      // AI 自动排序把外伝放到第 3 卷后（落盘不置手动标记）：下次归组不冲掉。
      final List<CollectionMemberKey> aiOrder = <CollectionMemberKey>[];
      final Map<String, String> uidByTitle = <String, String>{
        for (final EpubBookRow b in await db.getAllEpubBooks()) b.title: b.uid,
      };
      for (final String t in <String>[
        '志乃と恋 1',
        '志乃と恋 2',
        '志乃と恋 3',
        '志乃と恋 外伝',
      ]) {
        aiOrder.add((
          mediaType: MediaKind.epub.dbValue,
          entryKey: uidByTitle[t]!,
        ));
      }
      await db.reorderCollectionItemsAutomatically(id, aiOrder);
      expect((await grouper.groupAll()).updatedCollectionIds, isEmpty);
      expect(await members(id), <String>[
        '志乃と恋 1',
        '志乃と恋 2',
        '志乃と恋 3',
        '志乃と恋 外伝',
      ]);
    });

    test('用户手动排过的「主系列 + 番外」合集不自愈', () async {
      final (int id, _) = await addCollection('志乃と恋', <String>[
        '志乃と恋 2',
        '志乃と恋 SS',
        '志乃と恋 1',
      ]);
      await db.reorderCollectionItems(id, <CollectionMemberKey>[]);
      expect((await db.getMediaCollectionById(id))!.orderUpdatedAt, isNot(0));

      expect((await grouper.groupAll()).updatedCollectionIds, isEmpty);
      expect(await members(id), <String>['志乃と恋 2', '志乃と恋 SS', '志乃と恋 1']);
    });

    test('混了别的系列 / 认不出主系列 / 主系列卷号重复时不自愈', () async {
      // 别的系列（系列键不以主系列键开头）：主题合集，不碰。
      final (int mixed, _) = await addCollection('百合', <String>[
        '志乃と恋 2',
        '超かぐやメシ! 1',
        '志乃と恋 1',
      ]);
      // 两个系列各 2 卷：认不出主系列。
      final (int tied, _) = await addCollection('並列', <String>[
        'ABC 2',
        'ABCD 2',
        'ABC 1',
        'ABCD 1',
      ]);
      // 主系列两卷都没有卷号（同卷号判据：至多一卷无卷号）。
      final (int dup, _) = await addCollection('重複', <String>[
        'XYZ 2',
        'XYZ (上)',
        'XYZ',
        'XYZ 1',
      ]);

      expect((await grouper.groupAll()).updatedCollectionIds, isEmpty);
      expect(await members(mixed), <String>['志乃と恋 2', '超かぐやメシ! 1', '志乃と恋 1']);
      expect(await members(tied), <String>[
        'ABC 2',
        'ABCD 2',
        'ABC 1',
        'ABCD 1',
      ]);
      expect(await members(dup), <String>['XYZ 2', 'XYZ (上)', 'XYZ', 'XYZ 1']);
    });

    test('BookSeriesOrder.orderOf：番外原位、主系列按卷号；纯系列与输入顺序无关', () async {
      final String v1 = await addBook('志乃と恋 1');
      final String v2 = await addBook('志乃と恋 2');
      final String v3 = await addBook('志乃と恋 3');
      final String ex = await addBook('志乃と恋 外伝');
      CollectionMemberKey k(String uid) =>
          (mediaType: MediaKind.epub.dbValue, entryKey: uid);
      final BookSeriesOrder order = await BookSeriesOrder.load(db);

      expect(
        order.orderOf(<CollectionMemberKey>[k(ex), k(v3), k(v1), k(v2)]),
        <CollectionMemberKey>[k(ex), k(v1), k(v2), k(v3)],
      );
      expect(
        order.orderOf(<CollectionMemberKey>[k(v3), k(ex), k(v2), k(v1)]),
        <CollectionMemberKey>[k(v1), k(ex), k(v2), k(v3)],
      );
      expect(
        order.orderOf(<CollectionMemberKey>[k(v3), k(v2), k(v1)]),
        <CollectionMemberKey>[k(v1), k(v2), k(v3)],
      );
      expect(
        order.orderOf(<CollectionMemberKey>[
          k(v2),
          (mediaType: MediaKind.epub.dbValue, entryKey: 'remote-only'),
          k(v1),
        ]),
        isNull,
        reason: '本机没有的书（透传成员）认不全，不定序',
      );
    });

    test('规则卷序是全序：同卷配了两条 SRT 时结果也与输入顺序无关', () async {
      final String v1 = await addBook('志乃と恋 1', format: 'epub');
      final String v2 = await addBook('志乃と恋 2', format: 'epub');
      final String a = await addSrt('志乃と恋 2 a', bookKey: '志乃と恋 2');
      final String b = await addSrt('志乃と恋 2 b', bookKey: '志乃と恋 2');
      CollectionMemberKey epub(String uid) =>
          (mediaType: MediaKind.epub.dbValue, entryKey: uid);
      CollectionMemberKey srt(String uid) =>
          (mediaType: MediaKind.srt.dbValue, entryKey: uid);
      final BookSeriesOrder order = await BookSeriesOrder.load(db);

      final List<CollectionMemberKey> expected = <CollectionMemberKey>[
        epub(v1),
        epub(v2),
        srt(a),
        srt(b),
      ];
      expect(
        order.orderOf(<CollectionMemberKey>[
          srt(b),
          srt(a),
          epub(v2),
          epub(v1),
        ]),
        expected,
      );
      expect(
        order.orderOf(<CollectionMemberKey>[
          srt(a),
          epub(v1),
          srt(b),
          epub(v2),
        ]),
        expected,
        reason: '同卷同种类的并列按成员键定序，不靠 sort 稳定性',
      );
    });

    test('用户移出的卷不加回；删掉的合集不复活', () async {
      final String v1 = await addBook('志乃と恋 1');
      await addBook('志乃と恋 2');
      await addBook('志乃と恋 3');
      final int id = (await grouper.groupAll()).createdCollectionIds.single;

      await db.removeFromCollection(id, MediaKind.epub, v1);
      await grouper.groupAll();
      expect(await members(id), <String>[
        '志乃と恋 2',
        '志乃と恋 3',
      ], reason: '移出墓碑挡住重新加入');

      await db.deleteMediaCollection(id);
      final after = await grouper.groupAll();
      expect(after.createdCollectionIds, isEmpty, reason: '合集级删除墓碑挡住重建');
    });
  });

  group('存量脱离的配对有声书自愈', () {
    late FushiDatabase db;
    late BookSeriesGrouper grouper;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      grouper = BookSeriesGrouper(db);
    });

    tearDown(() => db.close());

    Future<String> addEpub(String title) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: title,
          title: title,
          epubPath: '/b/$title.epub',
          extractDir: '/b/$title',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1000,
          format: const Value<String>('epub'),
        ),
      );
      return (await db.resolveEpubBookUid(title))!;
    }

    Future<String> addDetachedPairedSrt(String bookKey) async {
      final String uid = 'srtbook_epub_$bookKey';
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: uid,
          title: bookKey,
          srtPath: '/s/$bookKey.srt',
          importedAt: 2000,
          bookKey: Value<String>(bookKey),
        ),
      );
      return uid;
    }

    Future<List<String>> members(int collectionId) async {
      final Map<String, String> titleByUid = <String, String>{
        for (final EpubBookRow b in await db.getAllEpubBooks()) b.uid: b.title,
        for (final SrtBookRow s in await db.getAllSrtBooks())
          s.uid: 'srt:${s.title}',
      };
      return <String>[
        for (final MediaCollectionItemRow item in await db.getCollectionItems(
          collectionId,
        ))
          titleByUid[item.entryKey] ?? item.entryKey,
      ];
    }

    test('系列合集里脱离的配对有声书在 groupAll 后自动补回且幂等', () async {
      await addEpub('安達としまむら');
      await addEpub('安達としまむら2');
      await addEpub('安達としまむら3');
      final int cid = (await grouper.groupAll()).createdCollectionIds.single;

      await addDetachedPairedSrt('安達としまむら2');

      final BookSeriesGroupSummary summary = await grouper.groupAll();
      expect(summary.updatedCollectionIds, contains(cid));
      expect(await members(cid), <String>[
        '安達としまむら',
        '安達としまむら2',
        'srt:安達としまむら2',
        '安達としまむら3',
      ]);
      final MediaCollectionRow col = (await db.getMediaCollectionById(cid))!;
      expect(col.origin, CollectionOrigin.rule.dbValue);

      final BookSeriesGroupSummary again = await grouper.groupAll();
      expect(again.createdCollectionIds, isEmpty);
      expect(again.updatedCollectionIds, isEmpty);
    });

    test('非系列手动合集里脱离的配对有声书同样自愈且不改写 orderUpdatedAt', () async {
      final String uidA = await addEpub('单卷甲');
      final String uidB = await addEpub('单卷乙');
      final int cid = await db.createMediaCollection('手动合集');
      await db.addToCollection(cid, MediaKind.epub, uidA);
      await db.addToCollection(cid, MediaKind.epub, uidB);
      await db.reorderCollectionItems(cid, <CollectionMemberKey>[
        (mediaType: MediaKind.epub.dbValue, entryKey: uidA),
        (mediaType: MediaKind.epub.dbValue, entryKey: uidB),
      ]);
      final int orderBefore = (await db.getMediaCollectionById(
        cid,
      ))!.orderUpdatedAt;
      expect(orderBefore, greaterThan(0));

      await addDetachedPairedSrt('单卷甲');

      final BookSeriesGroupSummary summary = await grouper.groupAll();
      expect(summary.updatedCollectionIds, contains(cid));
      expect(await members(cid), <String>['单卷甲', 'srt:单卷甲', '单卷乙']);
      expect(
        (await db.getMediaCollectionById(cid))!.orderUpdatedAt,
        orderBefore,
      );
    });

    test('自愈尊重用户移出墓碑；已在别的合集不妨碍补进原书合集', () async {
      await addEpub('志乃と恋 1');
      await addEpub('志乃と恋 2');
      await addEpub('志乃と恋 3');
      final int cid = (await grouper.groupAll()).createdCollectionIds.single;

      final String srt1 = await addDetachedPairedSrt('志乃と恋 1');
      final String srt3 = await addDetachedPairedSrt('志乃と恋 3');
      final int otherCid = await db.createMediaCollection('单独听力');
      await db.addToCollection(otherCid, MediaKind.srt, srt3);

      await grouper.groupAll();
      // SRT 卡在书架上顶替原书卡：原书在系列合集里，SRT 就得在，否则系列少一卷；
      // 用户另放进的「单独听力」不受影响。
      expect(await members(cid), <String>[
        '志乃と恋 1',
        'srt:志乃と恋 1',
        '志乃と恋 2',
        '志乃と恋 3',
        'srt:志乃と恋 3',
      ]);
      expect(await members(otherCid), <String>['srt:志乃と恋 3']);

      await db.removeFromCollection(cid, MediaKind.srt, srt1);
      final BookSeriesGroupSummary afterRemoval = await grouper.groupAll();
      expect(afterRemoval.updatedCollectionIds, isEmpty);
      expect(await members(cid), <String>[
        '志乃と恋 1',
        '志乃と恋 2',
        '志乃と恋 3',
        'srt:志乃と恋 3',
      ]);
      expect(await members(otherCid), <String>['srt:志乃と恋 3']);
    });
  });
}
