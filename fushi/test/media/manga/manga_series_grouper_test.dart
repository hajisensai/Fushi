import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_series_grouper.dart';
import 'package:fushi_engine/media/manga/manga_series_key.dart';

/// 本地漫画分卷按系列自动收进合集（用户漫画库「志乃と恋」1–4 卷散成四张卡）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseMangaSeriesKey（用户漫画库实际书名）', () {
    test('哈希后缀、全角 / 半角卷号、第N巻都归到同一系列', () {
      final Map<String, int?> volumes = <String, int?>{
        '志乃と恋 [3574f94a]': null,
        '志乃と恋 ２ [e11812e5]': 2,
        '志乃と恋 3 [998c5526]': 3,
        '志乃と恋 ４': 4,
        '志乃と恋 第5巻': 5,
        '志乃と恋 Vol.6': 6,
        '志乃と恋（7）': 7,
      };
      volumes.forEach((String title, int? volume) {
        final MangaSeriesKey key = parseMangaSeriesKey(title)!;
        expect(key.key, '志乃と恋', reason: title);
        expect(key.seriesTitle, '志乃と恋', reason: title);
        expect(key.volume, volume, reason: title);
      });
    });

    test('全角空格 + 卷号；书名本身的数字不被当卷号吃掉', () {
      final MangaSeriesKey shuu = parseMangaSeriesKey(
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
        parseMangaSeriesKey('週に一度クラスメイトを買う話 ~ふたりの時間、言い訳の五千円~ 2')!.key,
      );
      expect(parseMangaSeriesKey('86')!.volume, isNull);
      expect(parseMangaSeriesKey('86')!.key, '86');
      expect(parseMangaSeriesKey('3月のライオン')!.volume, isNull);
    });

    test('不同作品不撞键', () {
      expect(
        parseMangaSeriesKey('志乃と恋 Future')!.key,
        isNot(parseMangaSeriesKey('志乃と恋 3')!.key),
      );
    });
  });

  group('MangaSeriesGrouper', () {
    late FushiDatabase db;
    late MangaSeriesGrouper grouper;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      grouper = MangaSeriesGrouper(db);
    });

    tearDown(() => db.close());

    Future<String> addManga(
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

    Future<List<String>> memberTitles(int collectionId) async {
      final Map<String, String> titleByUid = <String, String>{
        for (final EpubBookRow b in await db.getAllEpubBooks()) b.uid: b.title,
      };
      return <String>[
        for (final MediaCollectionItemRow item in await db.getCollectionItems(
          collectionId,
        ))
          titleByUid[item.entryKey]!,
      ];
    }

    test('四卷叠成一个 playlist 合集，按卷号排；在线漫画与 EPUB 不进', () async {
      await addManga('志乃と恋 ４', importedAt: 1);
      await addManga('志乃と恋 3 [998c5526]', importedAt: 2);
      await addManga('志乃と恋 [3574f94a]', importedAt: 3);
      await addManga('志乃と恋 ２ [e11812e5]', importedAt: 4);
      await addManga('志乃と恋 Future', format: 'epub');
      await addManga(
        '志乃と恋',
        sourceMetadata: '{"type":"hibiki-online-manga","version":3}',
      );
      await addManga('超かぐやメシ!');

      final summary = await grouper.groupAll();

      expect(summary.createdCollectionIds, hasLength(1));
      final MediaCollectionRow collection = (await db.getMediaCollectionById(
        summary.createdCollectionIds.single,
      ))!;
      expect(collection.name, '志乃と恋');
      expect(collection.collectionType, 'playlist');
      expect(await memberTitles(collection.id), <String>[
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

    test('幂等；后来导入的单卷补进已有合集', () async {
      await addManga('志乃と恋 [3574f94a]');
      await addManga('志乃と恋 ２');
      final int id = (await grouper.groupAll()).createdCollectionIds.single;

      final again = await grouper.groupAll();
      expect(again.createdCollectionIds, isEmpty);
      expect(again.updatedCollectionIds, isEmpty);

      await addManga('志乃と恋 3');
      final later = await grouper.groupAll();
      expect(later.updatedCollectionIds, <int>[id]);
      expect(await memberTitles(id), <String>[
        '志乃と恋 [3574f94a]',
        '志乃と恋 ２',
        '志乃と恋 3',
      ]);
    });

    test('用户移出的卷不加回；删掉的合集不复活；已在别的合集里的卷不动', () async {
      final String v1 = await addManga('志乃と恋 1');
      await addManga('志乃と恋 2');
      final String v3 = await addManga('志乃と恋 3');
      final int manual = await db.createMediaCollection('百合');
      await db.addToCollection(manual, MediaKind.epub, v3);

      final int id = (await grouper.groupAll()).createdCollectionIds.single;
      expect(await memberTitles(id), <String>['志乃と恋 1', '志乃と恋 2']);
      expect(await memberTitles(manual), <String>['志乃と恋 3']);

      await db.removeFromCollection(id, MediaKind.epub, v1);
      await grouper.groupAll();
      expect(await memberTitles(id), <String>['志乃と恋 2'], reason: '移出墓碑挡住重新加入');

      await db.deleteMediaCollection(id);
      final after = await grouper.groupAll();
      expect(after.createdCollectionIds, isEmpty, reason: '合集级删除墓碑挡住重建');
    });
  });
}
