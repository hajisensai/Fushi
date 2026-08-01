/// 合集子篇封面闸测试（用户 2026-08-02：多集合集成员不得被自动刮成作品级海报）。
///
/// 覆盖四条：① 多集合集成员批量自动刮削不落海报（资料照刮、cover_meta 不动）；
/// ② 单片（无合集）照旧自动落海报；③ 单成员合集照旧；④ 用户手动匹配
/// （applyCandidateToBooks）对子篇永远放行。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/alias_cache.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/offline_index.dart';
import 'package:hibiki/src/media/video/scraper/cover_downloader.dart';
import 'package:hibiki/src/media/video/scraper/cover_scraper_service.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// 最小合法 PNG 魔数字节。
final List<int> _fakePng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x01, 0x02, 0x03,
];

MockClient _pngClient() => MockClient((http.Request req) async {
      return http.Response.bytes(
        _fakePng,
        200,
        headers: const <String, String>{'content-type': 'image/png'},
      );
    });

void main() {
  // 刮削落盘点走 evictLocalCoverCache（需要 PaintingBinding）。
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late VideoBookRepository repo;
  late Directory tmp;
  late CoverMetaStore coverMeta;
  late AliasCache aliasCache;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    tmp = await Directory.systemTemp.createTemp('member_cover_gate_');
    coverMeta = CoverMetaStore(tmp);
    aliasCache = AliasCache(tmp);
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
        coverDownloader: CoverDownloader(client: _pngClient()),
        offlineIndex: offline(),
        enableSidecar: false,
        coversDirectory: tmp,
      );

  test('多集合集成员批量自动刮削：不落海报、不写 cover_meta、资料照刮', () async {
    final VideoBookRow ep1 = await seed(
      bookUid: 'video/ep1',
      videoPath: p.join('anime', '进击的巨人', '进击的巨人 - 01.mkv'),
    );
    final VideoBookRow ep2 = await seed(
      bookUid: 'video/ep2',
      videoPath: p.join('anime', '进击的巨人', '进击的巨人 - 02.mkv'),
    );
    final int cid =
        await db.createMediaCollection('进击的巨人', collectionType: 'playlist');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');

    final List<BatchScrapeProgress> progress =
        await build().scrapeLibrary(<VideoBookRow>[ep1, ep2]).toList();

    for (final BatchScrapeProgress pr in progress) {
      expect(pr.outcome, isA<ScrapeSkippedProtected>(),
          reason: '子篇封面被闸住，走「只刮资料」路径');
    }
    for (final String uid in <String>['video/ep1', 'video/ep2']) {
      final VideoBookRow row = (await db.getVideoBookByBookUid(uid))!;
      expect(row.coverPath, isNull, reason: '子篇条目不落作品海报');
      expect(await coverMeta.get(uid), isNull,
          reason: '自动路径跳过时不得篡改/新增 cover_meta');
      expect(await repo.scrapeMetadata(uid), isNotNull,
          reason: '条目资料（简介/评分等）照刮不受影响');
    }
  });

  test('单片（无合集）照旧自动落海报', () async {
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

  test('单成员合集视为单片：照旧自动落海报', () async {
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
  });

  test('用户手动匹配（applyCandidateToBooks）对子篇永远放行', () async {
    await seed(
      bookUid: 'video/ep1',
      videoPath: p.join('anime', '进击的巨人', '进击的巨人 - 01.mkv'),
    );
    await seed(
      bookUid: 'video/ep2',
      videoPath: p.join('anime', '进击的巨人', '进击的巨人 - 02.mkv'),
    );
    final int cid =
        await db.createMediaCollection('进击的巨人', collectionType: 'playlist');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');

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
