import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:hibiki/src/media/video/scraper/collection_scrape_apply.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// BUG-1305 守卫：合集级刮削资料（schema v64）。
///
/// 根因：元数据此前只有 `video_scrape_meta` 一个宿主，主键 bookUid、外键指向
/// VideoBooks —— 它承载的是**单集**资料。而简介 / 评分 / 放送 / 标签本质属于「一部
/// 作品」，在统一合集模型里那就是合集。合集没有元数据宿主，于是合集刮削只能下一张
/// 海报就结束（`cover_match_dialog` 合集分支），详情页除标题和进度外一片空白，
/// 合集名也永远停在文件夹名。
void main() {
  /// 必须显式开 `foreign_keys`：`NativeDatabase.memory()` 默认关闭外键，而生产
  /// 路径是在 `applyPragmas` 里开的。不开的话本文件的 cascade 用例会「通过得毫无
  /// 意义」——它测的正是删合集连带清资料行这条约束。
  Future<HibikiDatabase> openDb() async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (CommonDatabase rawDb) =>
            rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    addTearDown(db.close);
    return db;
  }

  Future<int> newCollection(HibikiDatabase db, {String name = 'v2 播放列表'}) =>
      db.createMediaCollection(name);

  ScrapeMetadata meta({
    String title = '転生王女と天才令嬢の魔法革命',
    String? summary = '一部关于魔法的故事。',
    double? rating = 8.2,
    int? ratingCount = 1234,
    int? episodeCount = 12,
    List<ScrapeTag> tags = const <ScrapeTag>[
      ScrapeTag(name: '奇幻', count: 900),
      ScrapeTag(name: '百合', count: 800),
    ],
  }) =>
      ScrapeMetadata(
        source: ScrapeSource.tmdb,
        subjectId: '100',
        title: title,
        originalTitle: '転生王女',
        summary: summary,
        airDate: '2023-01-04',
        rating: rating,
        ratingCount: ratingCount,
        episodeCount: episodeCount,
        tags: tags,
        infobox: const <ScrapeInfoboxEntry>[
          ScrapeInfoboxEntry(key: '导演', value: '某人'),
        ],
        detailUrl: 'https://www.themoviedb.org/tv/100',
      );

  test('落库 → 读回：全字段往返，含横版背景路径', () async {
    final HibikiDatabase db = await openDb();
    final int id = await newCollection(db);

    await applyCollectionScrape(
      db,
      id,
      CollectionScrapeResult(
        coverPath: '/covers/collections/$id.jpg',
        backdropPath: '/covers/collections/${id}_backdrop.jpg',
        metadata: meta(),
      ),
    );

    final ({ScrapeMetadata metadata, String? backdropPath})? got =
        decodeCollectionScrapeMeta(await db.getCollectionScrapeMeta(id));
    expect(got, isNotNull);
    expect(got!.backdropPath, '/covers/collections/${id}_backdrop.jpg');
    expect(got.metadata.summary, '一部关于魔法的故事。');
    expect(got.metadata.rating, 8.2);
    expect(got.metadata.ratingCount, 1234);
    expect(got.metadata.episodeCount, 12);
    expect(got.metadata.airDate, '2023-01-04');
    expect(got.metadata.originalTitle, '転生王女');
    expect(
      got.metadata.tags.map((ScrapeTag t) => t.name).toList(),
      <String>['奇幻', '百合'],
      reason: '标签必须保序（源按热度降序），JSON 往返不得打乱',
    );
    expect(got.metadata.infobox.single.key, '导演');

    // 封面列与合集名同一次写入落地。
    final MediaCollectionRow? row = await db.getMediaCollectionById(id);
    expect(row!.coverPath, '/covers/collections/$id.jpg');
  });

  test('刮削回写合集名：文件夹名 → 条目正名', () async {
    final HibikiDatabase db = await openDb();
    final int id = await newCollection(db, name: 'Tensei Oujo v2 播放列表');

    await applyCollectionScrape(
      db,
      id,
      CollectionScrapeResult(
        coverPath: '/c.jpg',
        metadata: meta(title: '转生王女与天才令嬢的魔法革命'),
      ),
    );

    final MediaCollectionRow? row = await db.getMediaCollectionById(id);
    expect(
      row!.name,
      '转生王女与天才令嬢的魔法革命',
      reason: '合集刮削只有手动入口（用户亲手选中条目点「使用」），把文件夹名换成'
          '条目正名正是他要的结果',
    );
  });

  test('条目正名为空 → 保留原合集名，绝不改成空名字', () async {
    final HibikiDatabase db = await openDb();
    final int id = await newCollection(db, name: '我的播放列表');

    await applyCollectionScrape(
      db,
      id,
      CollectionScrapeResult(coverPath: '/c.jpg', metadata: meta(title: '   ')),
    );

    final MediaCollectionRow? row = await db.getMediaCollectionById(id);
    expect(row!.name, '我的播放列表');
  });

  test('原始条目名独立保存：事后手动改合集名不篡改「刮到的是什么」', () async {
    final HibikiDatabase db = await openDb();
    final int id = await newCollection(db);
    await applyCollectionScrape(
      db,
      id,
      CollectionScrapeResult(
          coverPath: '/c.jpg', metadata: meta(title: '条目正名')),
    );

    await db.renameMediaCollection(id, '我自己起的名字');

    final CollectionScrapeMetaRow? row = await db.getCollectionScrapeMeta(id);
    expect(row!.title, '条目正名');
    expect((await db.getMediaCollectionById(id))!.name, '我自己起的名字');
  });

  test('重刮覆盖同一行（不堆积历史行）', () async {
    final HibikiDatabase db = await openDb();
    final int id = await newCollection(db);
    await applyCollectionScrape(
        db,
        id,
        CollectionScrapeResult(
            coverPath: '/a.jpg', metadata: meta(rating: 7.0)));
    await applyCollectionScrape(
        db,
        id,
        CollectionScrapeResult(
            coverPath: '/b.jpg', metadata: meta(rating: 9.0)));

    final CollectionScrapeMetaRow? row = await db.getCollectionScrapeMeta(id);
    expect(row!.rating, 9.0);
    expect((await db.getMediaCollectionById(id))!.coverPath, '/b.jpg');
  });

  test('删合集 → FK cascade 连带清资料行（刮削缓存不留孤儿）', () async {
    final HibikiDatabase db = await openDb();
    final int id = await newCollection(db);
    await applyCollectionScrape(
        db, id, CollectionScrapeResult(coverPath: '/c.jpg', metadata: meta()));
    expect(await db.getCollectionScrapeMeta(id), isNotNull);

    await db.deleteMediaCollection(id);

    expect(
      await db.getCollectionScrapeMeta(id),
      isNull,
      reason: '刮削资料是可重建缓存，宿主没了就该跟着走，不留孤儿行',
    );
  });

  test('未刮过 → 返回 null（详情页据此回落到旧形态）', () async {
    final HibikiDatabase db = await openDb();
    final int id = await newCollection(db);
    expect(decodeCollectionScrapeMeta(await db.getCollectionScrapeMeta(id)),
        isNull);
  });

  test('JSON 列损坏 → 该列降级空列表，其余字段照常返回', () async {
    final HibikiDatabase db = await openDb();
    final int id = await newCollection(db);
    await applyCollectionScrape(
        db, id, CollectionScrapeResult(coverPath: '/c.jpg', metadata: meta()));
    // 手工写坏 tags 列，模拟旧版本/外部改动留下的非法 JSON。
    await db.customStatement(
      'UPDATE collection_scrape_meta SET tags_json = ? WHERE collection_id = ?',
      <Object?>['{not-a-list', id],
    );

    final ({ScrapeMetadata metadata, String? backdropPath})? got =
        decodeCollectionScrapeMeta(await db.getCollectionScrapeMeta(id));
    expect(got!.metadata.tags, isEmpty);
    expect(got.metadata.summary, '一部关于魔法的故事。', reason: '一列坏掉不得丢整条资料');
  });
}
