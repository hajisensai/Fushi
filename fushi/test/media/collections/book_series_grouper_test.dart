import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
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
