import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_series.dart';
import 'package:fushi_engine/media/collections/book_series_grouper.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';

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

    test('合集名保留原文写法；书名本身的数字不被当卷号吃掉', () {
      final BookSeriesKey shuu = parseBookSeriesKey(
        '週に一度クラスメイトを買う話 ～ふたりの時間、言い訳の五千円～　1',
      )!;
      expect(shuu.volume, 1);
      expect(
        shuu.seriesTitle,
        '週に一度クラスメイトを買う話 ～ふたりの時間、言い訳の五千円～',
        reason: '合集名保留原文的全角 ～，只有比较键折半角',
      );
      expect(
        shuu.key,
        parseBookSeriesKey('週に一度クラスメイトを買う話 ~ふたりの時間、言い訳の五千円~ 2')!.key,
      );
      expect(parseBookSeriesKey('86')!.volume, isNull);
      expect(parseBookSeriesKey('86─エイティシックス─')!.volume, isNull);
      expect(parseBookSeriesKey('3月のライオン')!.volume, isNull);
      expect(parseBookSeriesKey('Catch22')!.volume, isNull);
      expect(
        parseBookSeriesKey('志乃と恋 Future')!.key,
        isNot(parseBookSeriesKey('志乃と恋 3')!.key),
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
}
