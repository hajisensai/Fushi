import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 「书 ↔ 漫画」转化的落库面。
///
/// 转化最容易被想象成「跨表迁移」，实际不是：漫画与书是**同一张 `EpubBooks` 表**的
/// 行，靠 `format` 列区分，主键 `bookKey` 不变。因此统一媒体身份
/// `(mediaType='epub', entryKey=bookKey)` 完全不动——本测试的重点不是「字段写对了」，
/// 而是**连带引用一条都不断**：合集成员、标签、阅读进度、完成标记在转化后仍然指向
/// 同一本书。这是「转化不会让用户丢东西」的地基。
Future<HibikiDatabase> _openDb() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  const String key = 'Scanned Volume 01';

  Future<HibikiDatabase> seedImageEpub() async {
    final HibikiDatabase db = await _openDb();
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: 'scan.epub',
        extractDir: '/books/$key',
        chapterCount: 12,
        chaptersJson: '["c1","c2"]',
        importedAt: 1700000000000,
        coverPath: const Value<String>('cover.jpg'),
        author: const Value<String>('作者'),
      ),
    );
    return db;
  }

  test('转成漫画：format / 产物指针列一次写穿，extractDir 与身份不动', () async {
    final HibikiDatabase db = await seedImageEpub();

    await db.updateEpubBookFormat(
      key,
      format: 'manga',
      epubPath: 'manga.json',
      chapterCount: 180,
      chaptersJson: '[]',
      coverPath: 'images/page_0001.png',
    );

    final EpubBookRow? row = await db.getEpubBook(key);
    expect(row, isNotNull);
    expect(row!.format, 'manga');
    expect(row.epubPath, 'manga.json',
        reason: '漫画阅读器按 extractDir/epubPath 找 manga.json');
    expect(row.chapterCount, 180, reason: '漫画的 chapterCount 是页数');
    expect(row.chaptersJson, '[]');
    expect(row.coverPath, 'images/page_0001.png');
    expect(row.mangaReadingMode, isNull, reason: 'null = 跟随按页图比例自动判定');
    // 不该被动到的列。
    expect(row.bookKey, key, reason: '主键不变是整个转化设计的地基');
    expect(row.extractDir, '/books/$key', reason: '三种格式共用同一个书目录');
    expect(row.title, key);
    expect(row.author, '作者');
  });

  test('转回书：指回原始文件并清掉 mangaReadingMode（表约定：非漫画恒 null）', () async {
    final HibikiDatabase db = await seedImageEpub();
    await db.updateEpubBookFormat(
      key,
      format: 'manga',
      epubPath: 'manga.json',
      chapterCount: 180,
      chaptersJson: '[]',
      coverPath: 'images/page_0001.png',
      mangaReadingMode: 'webtoon',
    );
    expect((await db.getEpubBook(key))!.mangaReadingMode, 'webtoon');

    await db.updateEpubBookFormat(
      key,
      format: 'epub',
      epubPath: 'scan.epub',
      chapterCount: 12,
      chaptersJson: '["c1","c2"]',
      coverPath: 'cover.jpg',
    );

    final EpubBookRow row = (await db.getEpubBook(key))!;
    expect(row.format, 'epub');
    expect(row.epubPath, 'scan.epub');
    expect(row.mangaReadingMode, isNull,
        reason: '仅 format=manga 的行有意义，转回书必须清掉');
    expect(row.chaptersJson, '["c1","c2"]',
        reason: '转漫画时被覆盖成 []，转回来必须由重新解析原文件得到——所以反向也是重建');
  });

  test('转化后合集成员仍指向这本书（身份不变 → 零悬挂引用）', () async {
    final HibikiDatabase db = await seedImageEpub();
    final int collectionId = await db.createMediaCollection('扫描本');
    await db.addToCollection(collectionId, MediaKind.epub, key);

    await db.updateEpubBookFormat(
      key,
      format: 'manga',
      epubPath: 'manga.json',
      chapterCount: 180,
      chaptersJson: '[]',
      coverPath: 'images/page_0001.png',
    );

    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(collectionId);
    expect(items, hasLength(1));
    expect(items.single.entryKey, key);
    expect(items.single.mediaType, MediaKind.epub.dbValue,
        reason: '漫画在合集值域里就是 epub——MediaKind 里根本没有 manga');
  });

  test('转化后阅读进度与完成标记仍在（进度单位换轨是另一回事，行不能丢）', () async {
    final HibikiDatabase db = await seedImageEpub();
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookKey: key,
        sectionIndex: 3,
        normCharOffset: 4200,
        updatedAt: 1700000000000,
      ),
    );
    await db.setEpubBookCompleted(key, DateTime(2026, 7, 1));

    await db.updateEpubBookFormat(
      key,
      format: 'manga',
      epubPath: 'manga.json',
      chapterCount: 180,
      chaptersJson: '[]',
      coverPath: 'images/page_0001.png',
    );

    final ReaderPositionRow? pos = await db.getReaderPosition(key);
    expect(pos, isNotNull, reason: '进度行按 bookKey 关联，身份不变就不该丢');
    expect(pos!.sectionIndex, 3);
    expect((await db.getEpubBook(key))!.completedAt, isNotNull);
  });

  test('不传 coverPath = 保持原封面不变（绝不静默清空）', () async {
    final HibikiDatabase db = await seedImageEpub();
    expect((await db.getEpubBook(key))!.coverPath, 'cover.jpg');

    // 调用方只关心身份格式、没打算动封面：省略 coverPath。
    // 相邻的 updateEpubBookContentPaths 就是「null = 保持不变」，本方法必须同约定，
    // 否则漏传一个可选参数就把用户封面抹掉，且没有任何报错。
    await db.updateEpubBookFormat(
      key,
      format: 'manga',
      epubPath: 'manga.json',
      chapterCount: 180,
      chaptersJson: '[]',
    );

    final EpubBookRow row = (await db.getEpubBook(key))!;
    expect(row.coverPath, 'cover.jpg',
        reason: '省略 coverPath 必须保留原封面——写成 Value(coverPath) 会在此变成 null');
    expect(row.format, 'manga', reason: '其余列照常写穿');
  });

  test('显式传 coverPath 仍然覆盖（「不变」只适用于省略的情况）', () async {
    final HibikiDatabase db = await seedImageEpub();
    await db.updateEpubBookFormat(
      key,
      format: 'manga',
      epubPath: 'manga.json',
      chapterCount: 180,
      chaptersJson: '[]',
      coverPath: 'images/page_0001.png',
    );
    expect((await db.getEpubBook(key))!.coverPath, 'images/page_0001.png');
  });

  test('只影响目标行，同库其它书不受牵连', () async {
    final HibikiDatabase db = await seedImageEpub();
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'Another',
        title: 'Another',
        epubPath: 'other.epub',
        extractDir: '/books/Another',
        chapterCount: 5,
        chaptersJson: '[]',
        importedAt: 1700000000000,
      ),
    );

    await db.updateEpubBookFormat(
      key,
      format: 'manga',
      epubPath: 'manga.json',
      chapterCount: 180,
      chaptersJson: '[]',
      coverPath: 'images/page_0001.png',
    );

    final EpubBookRow other = (await db.getEpubBook('Another'))!;
    expect(other.format, 'epub');
    expect(other.epubPath, 'other.epub');
  });
}
