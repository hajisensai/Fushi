import 'package:drift/drift.dart' show Value, QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// v54 迁移（视频条目刮削「抄 Bangumi」）：新建 `video_scrape_meta` 表存条目级资料
/// （简介/评分/放送/话数/标签/infobox），封面仍走 `video_covers/` 文件 +
/// `cover_meta.json`，二者按 bookUid 对齐、互不覆盖。
///
/// 打开一个 user_version=53 的库（v53 shape：有 video_books，**无**
/// video_scrape_meta），触发真实 `if (from < 54)` 的 `createTable(videoScrapeMeta)`，
/// 验证：
///  ① 既有 video_books 行原样保留、表为纯新增（Never break userspace——旧库升级后
///     该表为空 = 全部未刮削，自动刮削逐步回填，封面/进度/字幕行为一字不变）；
///  ② 迁移后表存在且可写可读（含可空列与 JSON 列）；
///  ③ FK cascade 生效：删视频连带清资料行，不留孤儿；
///  ④ user_version 升到当前 schemaVersion（54）。
void main() {
  Future<HibikiDatabase> openV53Db() async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          // v53 shape：video_books 全列在场，但没有 video_scrape_meta 表。
          rawDb.execute('''
CREATE TABLE video_books (
  book_uid TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  video_path TEXT NOT NULL,
  subtitle_source TEXT,
  secondary_subtitle_source TEXT,
  subtitle_format TEXT,
  embedded_subtitle_track INTEGER,
  cover_path TEXT,
  last_position_ms INTEGER NOT NULL DEFAULT 0,
  imported_at INTEGER,
  playlist_json TEXT,
  current_episode INTEGER NOT NULL DEFAULT 0,
  audio_track_id TEXT,
  delay_ms INTEGER NOT NULL DEFAULT 0,
  completed_at INTEGER,
  source_id INTEGER,
  stream_spec_json TEXT
)
''');
          rawDb.execute(
            'INSERT INTO video_books '
            '(book_uid, title, video_path, last_position_ms, current_episode, '
            'delay_ms, cover_path) VALUES '
            "('legacy_video', '旧视频', 'D:/anime/legacy.mkv', 4200, 0, 0, "
            "'D:/covers/legacy.jpg')",
          );
          rawDb.execute('PRAGMA user_version = 53');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v54：既有 video_books 行零破坏，新表建出且初始为空', () async {
    final HibikiDatabase db = await openV53Db();

    final VideoBookRow? legacy = await db.getVideoBookByBookUid('legacy_video');
    expect(legacy, isNotNull, reason: '旧视频行原样保留');
    expect(legacy!.title, '旧视频');
    expect(legacy.lastPositionMs, 4200, reason: '进度不受新表影响');
    expect(legacy.coverPath, 'D:/covers/legacy.jpg', reason: '封面路径原样保留');

    // 新表已建出，且旧库升级后为空 = 全部未刮削。
    expect(await db.scrapedVideoBookUids(), isEmpty);
    expect(await db.getVideoScrapeMeta('legacy_video'), isNull);
  });

  test('v54：条目资料可写可读，可空列与 JSON 列往返', () async {
    final HibikiDatabase db = await openV53Db();

    await db.upsertVideoScrapeMeta(VideoScrapeMetaCompanion.insert(
      bookUid: 'legacy_video',
      source: 'bangumi',
      subjectId: '253',
      title: '星际牛仔',
      originalTitle: const Value<String?>('カウボーイビバップ'),
      summary: const Value<String?>('2071 年，人类离开了荒废的地球。'),
      airDate: const Value<String?>('1998-04-03'),
      rating: const Value<double?>(8.4),
      ratingCount: const Value<int?>(1234),
      episodeCount: const Value<int?>(26),
      tagsJson: const Value<String?>('[{"name":"科幻","count":900}]'),
      infoboxJson: const Value<String?>('[{"key":"导演","value":"渡辺信一郎"}]'),
      detailUrl: const Value<String?>('https://bgm.tv/subject/253'),
      scrapedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    ));

    final VideoScrapeMetaRow? row = await db.getVideoScrapeMeta('legacy_video');
    expect(row, isNotNull);
    expect(row!.source, 'bangumi');
    expect(row.subjectId, '253');
    expect(row.title, '星际牛仔');
    expect(row.originalTitle, 'カウボーイビバップ');
    expect(row.airDate, '1998-04-03', reason: '残缺日期存字符串，不转 DateTime 补月日');
    expect(row.rating, 8.4);
    expect(row.ratingCount, 1234);
    expect(row.episodeCount, 26);
    expect(row.tagsJson, contains('科幻'));
    expect(row.infoboxJson, contains('导演'));
    expect(await db.scrapedVideoBookUids(), <String>{'legacy_video'});

    // 主键是 bookUid：重刮同一本 = 覆盖而非新增一行。
    await db.upsertVideoScrapeMeta(VideoScrapeMetaCompanion.insert(
      bookUid: 'legacy_video',
      source: 'bangumi',
      subjectId: '999',
      title: '改过的条目',
      scrapedAt: DateTime.fromMillisecondsSinceEpoch(1700000001000),
    ));
    expect((await db.getVideoScrapeMeta('legacy_video'))!.subjectId, '999');
    expect(await db.scrapedVideoBookUids(), hasLength(1));

    await db.deleteVideoScrapeMeta('legacy_video');
    expect(await db.getVideoScrapeMeta('legacy_video'), isNull);
  });

  test('v54：删视频经 FK cascade 连带清资料行（fresh DB，FK 打开）', () async {
    // 用完整 schema 的 fresh 库 + 真实的 foreign_keys=ON（forTesting 吃裸
    // NativeDatabase，不走 _openDb 的 PRAGMA，默认 FK 是关的）。
    final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory(
      setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
    ));
    addTearDown(db.close);

    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('v1'),
      title: const Value<String>('片'),
      videoPath: const Value<String>('D:/anime/v1.mkv'),
    ));
    await db.upsertVideoScrapeMeta(VideoScrapeMetaCompanion.insert(
      bookUid: 'v1',
      source: 'bangumi',
      subjectId: '1',
      title: 't',
      scrapedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    ));
    expect(await db.getVideoScrapeMeta('v1'), isNotNull);

    await db.deleteVideoBook('v1');

    expect(await db.getVideoScrapeMeta('v1'), isNull, reason: '删视频不该留下孤儿刮削资料行');
  });

  test('v54：user_version 升到当前 schemaVersion', () async {
    final HibikiDatabase db = await openV53Db();
    await db.getVideoBookByBookUid('legacy_video'); // 触发 open/migrate。
    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 67);
  });
}
