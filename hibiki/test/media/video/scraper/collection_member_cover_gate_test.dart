/// 合集子篇封面闸 + 海报改投合集（BUG-1393 ①）。
///
/// 用户 2026-08-02：「子篇封面禁用作品级竖版海报：**作品海报只归合集封面**，成员
/// 条目保持抽帧/集级剧照，宁可无封面不凑数」。关键在「归合集封面」——只闸不改投
/// 会让多集合集卡从显示海报退化成显示首集抽帧，与用户口径相悖。
///
/// 覆盖：① 子篇不落成员封面**且**海报落到合集 coverPath；② 一合集只下一次海报；
/// ③ 合集已有自有封面时不覆盖；④ 单片 / 单成员合集照旧落成员海报；⑤ 用户手动
/// 匹配对子篇永远放行。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/alias_cache.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/cover_downloader.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/cover_scraper_service.dart';
import 'package:hibiki/src/media/video/scraper/offline_index.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_cover_extractor.dart'
    show videoCoverFileName;
import 'package:hibiki_core/hibiki_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// 最小合法 PNG 魔数字节。
const List<int> _fakePng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x01, 0x02, 0x03,
];

void main() {
  // 刮削落盘点走 evictLocalCoverCache（需要 PaintingBinding）。
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late VideoBookRepository repo;
  late Directory tmp;
  late Directory collectionCovers;
  late CoverMetaStore coverMeta;
  late AliasCache aliasCache;
  late int posterDownloads;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    tmp = await Directory.systemTemp.createTemp('member_cover_gate_');
    collectionCovers = Directory(p.join(tmp.path, 'collections'));
    await collectionCovers.create(recursive: true);
    coverMeta = CoverMetaStore(tmp);
    aliasCache = AliasCache(tmp);
    posterDownloads = 0;
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<VideoBookRow> seed({
    required String bookUid,
    required String videoPath,
  }) async {
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(bookUid),
      videoPath: Value(videoPath),
    ));
    return (await db.getVideoBookByBookUid(bookUid))!;
  }

  /// 「进击的巨人」离线库唯一精确命中记录（打分恒 high）。
  OfflineIndex offline() => OfflineIndex(const <OfflineAnimeRecord>[
        OfflineAnimeRecord(
          title: '进击的巨人',
          synonyms: <String>['Attack on Titan'],
          type: ScrapeEntryType.tv,
          episodes: 25,
          year: 2013,
          picture: 'https://img/aot.png',
          sourceId: 'myanimelist.net/anime/16498',
        ),
      ]);

  CoverScraperService build() => CoverScraperService(
        repository: repo,
        coverMetaStore: coverMeta,
        aliasCache: aliasCache,
        bangumiClient: BangumiClient(
          client: MockClient(
            (http.Request req) async => http.Response(
              '{"data":[]}',
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            ),
          ),
        ),
        coverDownloader: CoverDownloader(
          client: MockClient((http.Request req) async {
            posterDownloads++;
            return http.Response.bytes(
              _fakePng,
              200,
              headers: const <String, String>{'content-type': 'image/png'},
            );
          }),
        ),
        offlineIndex: offline(),
        enableSidecar: false,
        coversDirectory: tmp,
        collectionCoversDirectory: collectionCovers,
      );

  Future<int> seedSeries(String name) async {
    await seed(
      bookUid: 'video/ep1',
      videoPath: p.join('anime', name, '$name - 01.mkv'),
    );
    await seed(
      bookUid: 'video/ep2',
      videoPath: p.join('anime', name, '$name - 02.mkv'),
    );
    final int cid =
        await db.createMediaCollection(name, collectionType: 'playlist');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');
    return cid;
  }

  Future<List<VideoBookRow>> rows(List<String> uids) async => <VideoBookRow>[
        for (final String uid in uids) (await db.getVideoBookByBookUid(uid))!,
      ];

  test('多集合集：成员不落海报，海报改落合集 coverPath；一合集只下一次', () async {
    final int cid = await seedSeries('进击的巨人');

    final List<BatchScrapeProgress> progress = await build()
        .scrapeLibrary(await rows(<String>['video/ep1', 'video/ep2']))
        .toList();

    for (final BatchScrapeProgress pr in progress) {
      expect(pr.outcome, isA<ScrapeSkippedProtected>(),
          reason: '子篇成员封面被闸住，走「只刮资料」路径');
    }
    for (final String uid in <String>['video/ep1', 'video/ep2']) {
      final VideoBookRow row = (await db.getVideoBookByBookUid(uid))!;
      expect(row.coverPath, isNull, reason: '子篇条目不落作品海报');
      expect(await coverMeta.get(uid), isNull,
          reason: '自动路径跳过时不得篡改/新增 cover_meta');
      expect(await repo.scrapeMetadata(uid), isNotNull,
          reason: '条目资料（简介/评分等）照刮不受影响');
    }

    // ⚠️ 本轮的核心断言：海报**没有被丢弃**，而是落到了合集自有封面。
    final String expected =
        p.join(collectionCovers.path, videoCoverFileName('$cid'));
    expect((await db.getMediaCollectionById(cid))!.coverPath, expected,
        reason: '用户口径是「作品海报只归合集封面」，不是「作品海报消失」');
    expect(File(expected).existsSync(), isTrue);
    expect(posterDownloads, 1, reason: '26 集番不该发 26 次海报下载');
  });

  test('合集已有自有封面：自动路径不覆盖它，也不重下', () async {
    final int cid = await seedSeries('进击的巨人');
    final File own = File(p.join(collectionCovers.path, 'user_picked.jpg'));
    await own.writeAsBytes(<int>[0xFF, 0xD8, 0xFF, 0x42]);
    await db.updateMediaCollectionCoverPath(cid, own.path);

    await build()
        .scrapeLibrary(await rows(<String>['video/ep1', 'video/ep2']))
        .toList();

    expect((await db.getMediaCollectionById(cid))!.coverPath, own.path);
    expect(own.readAsBytesSync(), <int>[0xFF, 0xD8, 0xFF, 0x42]);
    expect(posterDownloads, 0, reason: '已有封面就不该出网');
  });

  test('单片（无合集）照旧自动落成员海报', () async {
    final VideoBookRow solo = await seed(
      bookUid: 'video/solo',
      videoPath: p.join('anime', '进击的巨人', '进击的巨人 - 04.mkv'),
    );
    final List<BatchScrapeProgress> progress =
        await build().scrapeLibrary(<VideoBookRow>[solo]).toList();
    expect(progress.single.outcome, isA<ScrapeApplied>());
    final VideoBookRow row = (await db.getVideoBookByBookUid('video/solo'))!;
    expect(row.coverPath, isNotNull);
    expect(File(row.coverPath!).existsSync(), isTrue);
  });

  test('单成员合集视为单片：照旧自动落成员海报，不写合集 coverPath', () async {
    final VideoBookRow single = await seed(
      bookUid: 'video/single',
      videoPath: p.join('anime', '进击的巨人', '进击的巨人 - 05.mkv'),
    );
    final int cid =
        await db.createMediaCollection('单成员', collectionType: 'collection');
    await db.addToCollection(cid, MediaKind.video, 'video/single');

    final List<BatchScrapeProgress> progress =
        await build().scrapeLibrary(<VideoBookRow>[single]).toList();
    expect(progress.single.outcome, isA<ScrapeApplied>());
    expect(
        (await db.getVideoBookByBookUid('video/single'))!.coverPath, isNotNull);
    expect((await db.getMediaCollectionById(cid))!.coverPath, isNull);
  });

  test('用户手动匹配（applyCandidateToBooks）对子篇永远放行', () async {
    await seedSeries('进击的巨人');

    await build().applyCandidateToBooks(
      bookUids: <String>['video/ep1'],
      candidate: const ScrapeCandidate(
        source: ScrapeSource.offlineDb,
        entryId: 'myanimelist.net/anime/16498',
        title: '进击的巨人',
        posterUrl: 'https://img/aot.png',
      ),
    );

    final VideoBookRow row = (await db.getVideoBookByBookUid('video/ep1'))!;
    expect(row.coverPath, isNotNull, reason: '用户亲手拍板不经子篇闸');
    final CoverMeta? meta = await coverMeta.get('video/ep1');
    expect(meta!.origin, CoverOrigin.userScraped);
  });
}
