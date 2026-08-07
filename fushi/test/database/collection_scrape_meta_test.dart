import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:fushi/src/media/video/scraper/collection_scrape_apply.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1310 守卫：合集级刮削资料（schema v64）。
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
  Future<FushiDatabase> openDb() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (CommonDatabase rawDb) =>
            rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    addTearDown(db.close);
    return db;
  }

  Future<int> newCollection(FushiDatabase db, {String name = 'v2 播放列表'}) =>
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

  test('落库 → 读回：全字段往返，附加图组落 media_images（v68）', () async {
    final FushiDatabase db = await openDb();
    final int id = await newCollection(db);

    await applyCollectionScrape(
      db,
      id,
      CollectionScrapeResult(
        coverPath: '/covers/collections/$id.jpg',
        images: <ScrapedMediaImage>[
          ScrapedMediaImage(
            kind: MediaImageKind.backdrop,
            path: '/covers/collections/${id}_backdrop0.jpg',
            sourceUrl: 'https://img/b0.jpg',
          ),
          ScrapedMediaImage(
            kind: MediaImageKind.backdrop,
            position: 1,
            path: '/covers/collections/${id}_backdrop1.jpg',
          ),
          ScrapedMediaImage(
            kind: MediaImageKind.logo,
            path: '/covers/collections/${id}_logo.png',
          ),
          ScrapedMediaImage(
            kind: MediaImageKind.titleCard,
            path: '/covers/collections/${id}_titlecard.jpg',
          ),
        ],
        metadata: meta(),
      ),
      confirmedTitle: null,
    );

    final ScrapeMetadata? got =
        decodeCollectionScrapeMeta(await db.getCollectionScrapeMeta(id));
    expect(got, isNotNull);
    expect(got!.summary, '一部关于魔法的故事。');
    expect(got.rating, 8.2);
    expect(got.ratingCount, 1234);
    expect(got.episodeCount, 12);
    expect(got.airDate, '2023-01-04');
    expect(got.originalTitle, '転生王女');
    expect(
      got.tags.map((ScrapeTag t) => t.name).toList(),
      <String>['奇幻', '百合'],
      reason: '标签必须保序（源按热度降序），JSON 往返不得打乱',
    );
    expect(got.infobox.single.key, '导演');

    // v68：附加图组整组落 media_images，遗留 backdrop_path 列恒 NULL
    // （单一真相源，两处都有值必然漂开）。
    final CollectionScrapeMetaRow? metaRow =
        await db.getCollectionScrapeMeta(id);
    expect(metaRow!.backdropPath, isNull, reason: 'v68 起旧列冻结，新刮削不得再写它');
    final List<MediaImageRow> images = await db.getMediaImagesForCollection(id);
    expect(images, hasLength(4));
    final List<MediaImageRow> backdrops = <MediaImageRow>[
      for (final MediaImageRow r in images)
        if (r.kind == MediaImageKind.backdrop.dbValue) r,
    ];
    expect(backdrops, hasLength(2), reason: 'backdrop 是唯一允许多张的种类');
    expect(backdrops.first.position, 0);
    expect(backdrops.first.sourceUrl, 'https://img/b0.jpg');
    expect(backdrops.last.position, 1);

    // 封面列与合集名同一次写入落地。
    final MediaCollectionRow? row = await db.getMediaCollectionById(id);
    expect(row!.coverPath, '/covers/collections/$id.jpg');
  });

  test('删合集 → media_images 行 FK cascade 清空（v68）', () async {
    final FushiDatabase db = await openDb();
    final int id = await newCollection(db);
    await applyCollectionScrape(
      db,
      id,
      CollectionScrapeResult(
        coverPath: '/c.jpg',
        images: <ScrapedMediaImage>[
          ScrapedMediaImage(
            kind: MediaImageKind.backdrop,
            path: '/covers/collections/${id}_backdrop0.jpg',
          ),
        ],
        metadata: meta(),
      ),
      confirmedTitle: null,
    );
    expect(await db.getMediaImagesForCollection(id), hasLength(1));

    await db.deleteMediaCollection(id);
    expect(
      await db.getAllMediaImages(),
      isEmpty,
      reason: '删合集必须连带清附加图行——否则孤儿行指向已删合集，永远无法回收',
    );
  });

  test('用户确认后才回写合集名：文件夹名 → 条目正名', () async {
    final FushiDatabase db = await openDb();
    final int id = await newCollection(db, name: 'Tensei Oujo v2 播放列表');

    await applyCollectionScrape(
      db,
      id,
      CollectionScrapeResult(
        coverPath: '/c.jpg',
        metadata: meta(title: '转生王女与天才令嬢的魔法革命'),
      ),
      confirmedTitle: '转生王女与天才令嬢的魔法革命',
    );

    final MediaCollectionRow? row = await db.getMediaCollectionById(id);
    expect(
      row!.name,
      '转生王女与天才令嬢的魔法革命',
      reason: '用户在确认弹窗里看着「旧名 → 新名」点了确认，就该照写',
    );
  });

  // ── 契约 ①：用户不确认 → 不写库、不产生旧名墓碑 ──────────────────
  //
  // 这是 BUG-1310 复议的核心口径。改合集名不是本地改个字段：renameMediaCollection
  // 会给旧 (name,type) 写合集级墓碑，同步出去后**其他设备上的旧名副本会被删掉**。
  // 用户没点确认时这条链一环都不许启动。
  test('用户不确认 → 合集名一字不动，且不产生任何旧名同步墓碑', () async {
    final FushiDatabase db = await openDb();
    final int id = await newCollection(db, name: 'Tensei Oujo v2 播放列表');
    final int tombstonesBefore =
        (await db.select(db.collectionMemberTombstones).get()).length;

    await applyCollectionScrape(
      db,
      id,
      CollectionScrapeResult(
        coverPath: '/c.jpg',
        metadata: meta(title: '转生王女与天才令嬢的魔法革命'),
      ),
      confirmedTitle: null,
    );

    final MediaCollectionRow? row = await db.getMediaCollectionById(id);
    expect(
      row!.name,
      'Tensei Oujo v2 播放列表',
      reason: '没确认就静默改名 = 用户既没被告知也无从撤销，正是本 bug 的根因',
    );
    // 封面和资料照旧落地：拒绝改名不等于拒绝整次刮削。
    expect(row.coverPath, '/c.jpg');
    expect(await db.getCollectionScrapeMeta(id), isNotNull);
    // 墓碑一条都不许多：多一条就意味着其他设备上的旧名副本会被删。
    final List<CollectionMemberTombstoneRow> tombstones =
        await db.select(db.collectionMemberTombstones).get();
    expect(
      tombstones.length,
      tombstonesBefore,
      reason: '未确认改名却写了合集墓碑 → 同步出去会删掉其他设备上的旧名副本，'
          '实际墓碑：${tombstones.map((CollectionMemberTombstoneRow r) => '${r.collectionName}/${r.mediaType}').toList()}',
    );
    expect(
      tombstones.where((CollectionMemberTombstoneRow r) =>
          r.collectionName == 'Tensei Oujo v2 播放列表'),
      isEmpty,
    );
  });

  test('确认名为空白 → 保留原合集名，绝不改成空名字', () async {
    final FushiDatabase db = await openDb();
    final int id = await newCollection(db, name: '我的播放列表');

    await applyCollectionScrape(
      db,
      id,
      CollectionScrapeResult(coverPath: '/c.jpg', metadata: meta(title: '   ')),
      confirmedTitle: '   ',
    );

    final MediaCollectionRow? row = await db.getMediaCollectionById(id);
    expect(row!.name, '我的播放列表');
  });

  // ── 契约 ②：自动刮削路径永不触发改名 ──────────────────────────
  //
  // 源码扫描守卫：合集改名的唯一入口是 applyCollectionScrape 的 confirmedTitle，
  // 而该参数只由「在线匹配封面」弹窗的确认结果填。自动刮削服务若哪天摸到合集写入，
  // 这条断言立刻红——比等真机上发现「后台把我的合集名改了」早得多。
  test('自动刮削服务不碰合集：源码里零合集写入调用', () async {
    final File auto =
        File('lib/src/media/video/scraper/auto_scrape_service.dart');
    expect(auto.existsSync(), isTrue, reason: '自动刮削服务文件路径变了就来更新本守卫');
    final String src = auto.readAsStringSync();
    for (final String forbidden in <String>[
      'applyCollectionScrape',
      'renameMediaCollection',
      'upsertCollectionScrapeMeta',
      'updateMediaCollectionCoverPath',
    ]) {
      expect(
        src.contains(forbidden),
        isFalse,
        reason: '自动刮削（后台批量）出现 $forbidden：合集刮削与改名只允许走用户'
            '亲手确认的手动入口，后台绝不能悄悄改名/改合集封面',
      );
    }
  });

  test('proposedCollectionRename：只在真有变化时才提议询问', () {
    // 有变化 → 提议（trim 后的名字，用户看到什么就写什么）。
    expect(
      proposedCollectionRename(currentName: '文件夹名', scrapedTitle: ' 正名 '),
      '正名',
    );
    // 同名 → 不问（renameMediaCollection 对同名是 no-op，问了只是噪音）。
    expect(
      proposedCollectionRename(currentName: '正名', scrapedTitle: '正名'),
      isNull,
    );
    // 空正名 → 不问（改成空名字本就不允许）。
    expect(
      proposedCollectionRename(currentName: '文件夹名', scrapedTitle: '  '),
      isNull,
    );
  });

  test('原始条目名独立保存：事后手动改合集名不篡改「刮到的是什么」', () async {
    final FushiDatabase db = await openDb();
    final int id = await newCollection(db);
    await applyCollectionScrape(
      db,
      id,
      CollectionScrapeResult(
          coverPath: '/c.jpg', metadata: meta(title: '条目正名')),
      confirmedTitle: '条目正名',
    );

    await db.renameMediaCollection(id, '我自己起的名字');

    final CollectionScrapeMetaRow? row = await db.getCollectionScrapeMeta(id);
    expect(row!.title, '条目正名');
    expect((await db.getMediaCollectionById(id))!.name, '我自己起的名字');
  });

  test('重刮覆盖同一行（不堆积历史行）', () async {
    final FushiDatabase db = await openDb();
    final int id = await newCollection(db);
    await applyCollectionScrape(
        db,
        id,
        CollectionScrapeResult(
            coverPath: '/a.jpg', metadata: meta(rating: 7.0)),
        confirmedTitle: null);
    await applyCollectionScrape(
        db,
        id,
        CollectionScrapeResult(
            coverPath: '/b.jpg', metadata: meta(rating: 9.0)),
        confirmedTitle: null);

    final CollectionScrapeMetaRow? row = await db.getCollectionScrapeMeta(id);
    expect(row!.rating, 9.0);
    expect((await db.getMediaCollectionById(id))!.coverPath, '/b.jpg');
  });

  test('删合集 → FK cascade 连带清资料行（刮削缓存不留孤儿）', () async {
    final FushiDatabase db = await openDb();
    final int id = await newCollection(db);
    await applyCollectionScrape(
        db, id, CollectionScrapeResult(coverPath: '/c.jpg', metadata: meta()),
        confirmedTitle: null);
    expect(await db.getCollectionScrapeMeta(id), isNotNull);

    await db.deleteMediaCollection(id);

    expect(
      await db.getCollectionScrapeMeta(id),
      isNull,
      reason: '刮削资料是可重建缓存，宿主没了就该跟着走，不留孤儿行',
    );
  });

  test('未刮过 → 返回 null（详情页据此回落到旧形态）', () async {
    final FushiDatabase db = await openDb();
    final int id = await newCollection(db);
    expect(decodeCollectionScrapeMeta(await db.getCollectionScrapeMeta(id)),
        isNull);
  });

  test('JSON 列损坏 → 该列降级空列表，其余字段照常返回', () async {
    final FushiDatabase db = await openDb();
    final int id = await newCollection(db);
    await applyCollectionScrape(
        db, id, CollectionScrapeResult(coverPath: '/c.jpg', metadata: meta()),
        confirmedTitle: null);
    // 手工写坏 tags 列，模拟旧版本/外部改动留下的非法 JSON。
    await db.customStatement(
      'UPDATE collection_scrape_meta SET tags_json = ? WHERE collection_id = ?',
      <Object?>['{not-a-list', id],
    );

    final ScrapeMetadata? got =
        decodeCollectionScrapeMeta(await db.getCollectionScrapeMeta(id));
    expect(got!.tags, isEmpty);
    expect(got.summary, '一部关于魔法的故事。', reason: '一列坏掉不得丢整条资料');
  });
}
