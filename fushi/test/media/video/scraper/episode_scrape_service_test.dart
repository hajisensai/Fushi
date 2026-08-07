import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/bangumi_client.dart';
import 'package:fushi/src/media/video/scraper/cover_downloader.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/episode_scrape_service.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/scraper/tmdb_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

/// TODO-2491：集级刮削服务守卫。全部走内存 DB + MockClient + 临时目录，无真实
/// 网络。覆盖：集号对齐（缺集/无集号/重复集号）、Bangumi/TMDB 两源解析、剧照
/// 落集封面且**绝不覆盖用户手选封面**、movie 条目无分集的显式报错。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  Future<int> boundCollection(
    FushiDatabase db, {
    String name = '本篇',
    String source = 'bangumi',
    String subjectId = '100',
    String? detailUrl,
  }) async {
    final int id = await db.createMediaCollection(name);
    await db.upsertCollectionScrapeMeta(CollectionScrapeMetaCompanion.insert(
      collectionId: Value<int>(id),
      source: source,
      subjectId: subjectId,
      title: name,
      detailUrl: Value<String?>(detailUrl),
      scrapedAt: DateTime(2026),
    ));
    return id;
  }

  Future<void> addVideoMember(
    FushiDatabase db,
    int collectionId,
    String uid,
    String fileName, {
    String? coverPath,
  }) async {
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: uid,
      title: uid,
      videoPath: '/videos/$fileName',
      coverPath: Value<String?>(coverPath),
    ));
    await db.addToCollectionRaw(collectionId, 'video', uid);
  }

  MockClient bangumiEpisodesClient(List<Map<String, Object?>> episodes) =>
      MockClient((http.Request req) async {
        if (req.url.path.endsWith('/episodes')) {
          return http.Response.bytes(
            utf8.encode(jsonEncode(<String, Object?>{
              'data': episodes,
              'total': episodes.length,
            })),
            200,
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('not found', 404);
      });

  group('parseBangumiEpisodesResponse', () {
    test('keeps integer main-episode sorts, drops fractional or zero', () {
      final ({
        List<BangumiEpisodeInfo> episodes,
        int rawCount,
        int total
      }) page = parseBangumiEpisodesResponse(jsonEncode(<String, Object?>{
        'total': 4,
        'data': <Object?>[
          <String, Object?>{
            'sort': 1,
            'name_cn': '第一话',
            'airdate': '2023-01-04'
          },
          <String, Object?>{'sort': 2.0, 'name': 'Ep2'},
          <String, Object?>{'sort': 2.5, 'name': '番外混入'},
          <String, Object?>{'sort': 0, 'name': '零号'},
        ],
      }));
      expect(page.total, 4);
      expect(page.rawCount, 4, reason: '分页 offset 按原始条数推进，不受过滤影响');
      expect(page.episodes.map((BangumiEpisodeInfo e) => e.episodeNumber),
          <int>[1, 2]);
      expect(page.episodes.first.title, '第一话');
    });

    test('抽取源侧章节 id（bgm.tv/ep/<id> 外链用），缺失容错为 null', () {
      final ({
        List<BangumiEpisodeInfo> episodes,
        int rawCount,
        int total
      }) page = parseBangumiEpisodesResponse(jsonEncode(<String, Object?>{
        'total': 2,
        'data': <Object?>[
          <String, Object?>{'id': 1234, 'sort': 1, 'name': 'Ep1'},
          <String, Object?>{'sort': 2, 'name': 'Ep2'},
        ],
      }));
      expect(page.episodes.first.id, 1234);
      expect(page.episodes.last.id, isNull);
    });
  });

  group('bangumi episode alignment', () {
    test(
        'writes per-episode meta, counts unmatched (no episode number / '
        'missing on source), duplicates both written', () async {
      final FushiDatabase db = await openDb();
      final int id = await boundCollection(db);
      await addVideoMember(db, id, 'u1', '[Grp] Show - 01.mkv');
      await addVideoMember(db, id, 'u1b', '[Grp] Show - 01v2.mkv');
      await addVideoMember(db, id, 'u2', '[Grp] Show - 02.mkv');
      await addVideoMember(db, id, 'u3', '[Grp] Show - 03.mkv'); // 源缺第 3 集
      await addVideoMember(db, id, 'um', 'Show Movie SP.mkv'); // 解不出集号

      final BangumiClient bangumi = BangumiClient(
        client: bangumiEpisodesClient(<Map<String, Object?>>[
          <String, Object?>{
            'sort': 1,
            'name_cn': '出会い',
            'airdate': '2023-01-04',
            'desc': '第一话简介',
          },
          <String, Object?>{'sort': 2, 'name': '第二话'},
        ]),
      );
      addTearDown(bangumi.close);

      final EpisodeScrapeService service =
          EpisodeScrapeService(db: db, bangumiClient: bangumi);
      final EpisodeScrapeOutcome outcome =
          await service.scrapeCollectionEpisodes(id);

      expect(outcome.errors, isEmpty);
      expect(outcome.updated, 3, reason: 'u1 + u1b（重复集号双版本）+ u2');
      expect(outcome.unmatched, 2, reason: 'u3 源缺集 + um 解不出集号');

      final VideoScrapeMetaRow? u1 = await db.getVideoScrapeMeta('u1');
      expect(u1, isNotNull);
      expect(u1!.episodeNumber, 1);
      expect(u1.title, '出会い');
      expect(u1.airDate, '2023-01-04');
      expect(u1.summary, '第一话简介');
      expect(u1.source, 'bangumi');
      expect((await db.getVideoScrapeMeta('u1b'))!.episodeNumber, 1,
          reason: '重复集号（v2 版本文件）同资料各写各的');
      expect((await db.getVideoScrapeMeta('u2'))!.title, '第二话');
      expect(await db.getVideoScrapeMeta('u3'), isNull);
      expect(await db.getVideoScrapeMeta('um'), isNull);
    });

    test('episode title falls back to work title when source omits it',
        () async {
      final FushiDatabase db = await openDb();
      final int id = await boundCollection(db, name: '作品名');
      await addVideoMember(db, id, 'u1', 'Show - 01.mkv');
      final BangumiClient bangumi = BangumiClient(
        client: bangumiEpisodesClient(<Map<String, Object?>>[
          <String, Object?>{'sort': 1},
        ]),
      );
      addTearDown(bangumi.close);
      await EpisodeScrapeService(db: db, bangumiClient: bangumi)
          .scrapeCollectionEpisodes(id);
      expect((await db.getVideoScrapeMeta('u1'))!.title, '作品名');
    });

    test('source failure reports error and writes nothing', () async {
      final FushiDatabase db = await openDb();
      final int id = await boundCollection(db);
      await addVideoMember(db, id, 'u1', 'Show - 01.mkv');
      final BangumiClient bangumi = BangumiClient(
        client:
            MockClient((http.Request req) async => http.Response('boom', 500)),
      );
      addTearDown(bangumi.close);
      final EpisodeScrapeOutcome outcome =
          await EpisodeScrapeService(db: db, bangumiClient: bangumi)
              .scrapeCollectionEpisodes(id);
      expect(outcome.errors, isNotEmpty, reason: '源失败必须上报不吞');
      expect(outcome.updated, 0);
      expect(await db.getVideoScrapeMeta('u1'), isNull);
    });

    test('missing scrape binding throws StateError', () async {
      final FushiDatabase db = await openDb();
      final int bare = await db.createMediaCollection('未刮削');
      expect(
        () => EpisodeScrapeService(db: db).scrapeCollectionEpisodes(bare),
        throwsStateError,
      );
    });
  });

  group('tmdb stills', () {
    // 最小合法 JPEG 头（魔数 FF D8 FF），CoverDownloader 的图片嗅探要求。
    final List<int> jpegBytes = <int>[
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0x00,
      0x10,
      0x4A,
      0x46,
      0x49,
      0x46,
    ];

    test(
        'applies stills as episode covers, never overwrites user-chosen '
        'cover, season from filename majority', () async {
      final FushiDatabase db = await openDb();
      final int id = await boundCollection(
        db,
        source: 'tmdb',
        subjectId: '77',
        detailUrl: 'https://www.themoviedb.org/tv/77',
      );
      await addVideoMember(db, id, 'u1', 'Show S02E01.mkv',
          coverPath: '/covers/manual-u1.jpg');
      await addVideoMember(db, id, 'u2', 'Show S02E02.mkv');

      final List<String> seasonRequests = <String>[];
      final TmdbClient tmdb = TmdbClient(
        apiKey: 'k',
        client: MockClient((http.Request req) async {
          seasonRequests.add(req.url.path);
          return http.Response.bytes(
            utf8.encode(jsonEncode(<String, Object?>{
              'episodes': <Object?>[
                <String, Object?>{
                  'episode_number': 1,
                  'name': '一话',
                  'overview': '概要一',
                  'air_date': '2024-04-01',
                  'still_path': '/still1.jpg',
                },
                <String, Object?>{
                  'episode_number': 2,
                  'name': '二话',
                  'still_path': '/still2.jpg',
                },
              ],
            })),
            200,
          );
        }),
      );
      addTearDown(tmdb.close);

      final Directory coversDir =
          await Directory.systemTemp.createTemp('ep_stills_');
      addTearDown(() => coversDir.delete(recursive: true));
      final CoverMetaStore metaStore = CoverMetaStore(coversDir);
      // u1 的封面是用户手选：绝不覆盖（TODO-2491 防线）。
      await metaStore.set('u1', const CoverMeta(origin: CoverOrigin.manual));

      final CoverDownloader downloader = CoverDownloader(
        client: MockClient((http.Request req) async => http.Response.bytes(
            jpegBytes, 200,
            headers: <String, String>{'content-type': 'image/jpeg'})),
      );

      final EpisodeScrapeService service = EpisodeScrapeService(
        db: db,
        tmdbClient: tmdb,
        coverDownloader: downloader,
        coverMetaStore: metaStore,
        coversDirectory: coversDir,
      );
      final EpisodeScrapeOutcome outcome =
          await service.scrapeCollectionEpisodes(id);

      expect(outcome.errors, isEmpty);
      expect(outcome.updated, 2);
      expect(seasonRequests.single, '/3/tv/77/season/2',
          reason: '成员均为 S02 → 只拉 season 2');

      // u1：资料写入但封面纹丝不动。
      expect((await db.getVideoScrapeMeta('u1'))!.title, '一话');
      final VideoBookRow u1 = (await db.getVideoBookByBookUid('u1'))!;
      expect(u1.coverPath, '/covers/manual-u1.jpg', reason: '用户手选封面绝不被剧照覆盖');
      expect(outcome.stillsSkippedUserCover, 1);
      expect((await metaStore.get('u1'))!.origin, CoverOrigin.manual);

      // u2：剧照落为封面 + cover_meta 标 autoScraped。
      expect(outcome.stillsApplied, 1);
      final VideoBookRow u2 = (await db.getVideoBookByBookUid('u2'))!;
      expect(u2.coverPath, isNotNull);
      expect(File(u2.coverPath!).existsSync(), isTrue,
          reason: '剧照必须真实落盘到 covers 目录');
      final CoverMeta? u2Meta = await metaStore.get('u2');
      expect(u2Meta!.origin, CoverOrigin.autoScraped);
      expect(u2Meta.source, ScrapeSource.tmdb);
    });

    test('movie subject has no episodes and says so', () async {
      final FushiDatabase db = await openDb();
      final int id = await boundCollection(
        db,
        source: 'tmdb',
        subjectId: '55',
        detailUrl: 'https://www.themoviedb.org/movie/55',
      );
      await addVideoMember(db, id, 'u1', 'Movie.mkv');
      final TmdbClient tmdb = TmdbClient(
        apiKey: 'k',
        client: MockClient(
            (http.Request req) async => http.Response('unexpected', 500)),
      );
      addTearDown(tmdb.close);
      final EpisodeScrapeOutcome outcome =
          await EpisodeScrapeService(db: db, tmdbClient: tmdb)
              .scrapeCollectionEpisodes(id);
      expect(outcome.errors['tmdb'], contains('movie'),
          reason: 'movie 条目无分集：显式报错而不是装作零匹配');
      expect(outcome.updated, 0);
    });
  });

  group('mixed seasons and pagination', () {
    test('mixed-season members each align against their own season table',
        () async {
      final FushiDatabase db = await openDb();
      final int id = await boundCollection(
        db,
        source: 'tmdb',
        subjectId: '77',
        detailUrl: 'https://www.themoviedb.org/tv/77',
      );
      await addVideoMember(db, id, 'u1', 'Show S01E01.mkv');
      await addVideoMember(db, id, 'u2', 'Show S02E01.mkv');

      final List<String> seasonRequests = <String>[];
      final TmdbClient tmdb = TmdbClient(
        apiKey: 'k',
        client: MockClient((http.Request req) async {
          seasonRequests.add(req.url.path);
          final Map<String, List<Map<String, Object?>>> episodesBySeason =
              <String, List<Map<String, Object?>>>{
            '/3/tv/77/season/1': <Map<String, Object?>>[
              <String, Object?>{'episode_number': 1, 'name': '一季一话'},
            ],
            '/3/tv/77/season/2': <Map<String, Object?>>[
              <String, Object?>{'episode_number': 1, 'name': '二季一话'},
            ],
          };
          final List<Map<String, Object?>>? episodes =
              episodesBySeason[req.url.path];
          if (episodes == null) return http.Response('not found', 404);
          return http.Response.bytes(
            utf8.encode(jsonEncode(<String, Object?>{'episodes': episodes})),
            200,
          );
        }),
      );
      addTearDown(tmdb.close);

      final EpisodeScrapeOutcome outcome =
          await EpisodeScrapeService(db: db, tmdbClient: tmdb)
              .scrapeCollectionEpisodes(id);
      expect(outcome.errors, isEmpty);
      expect(outcome.updated, 2);
      expect(seasonRequests.toSet(),
          <String>{'/3/tv/77/season/1', '/3/tv/77/season/2'},
          reason: '按成员出现的每个季各拉一次');
      expect((await db.getVideoScrapeMeta('u1'))!.title, '一季一话',
          reason: 'S01 成员对齐第 1 季分集表');
      expect((await db.getVideoScrapeMeta('u2'))!.title, '二季一话',
          reason: 'S02 成员对齐第 2 季分集表，不被另一季错配');
    });

    test(
        'bangumi pagination advances by raw count across fully-filtered '
        'pages', () async {
      final List<int> offsets = <int>[];
      final BangumiClient bangumi = BangumiClient(
        client: MockClient((http.Request req) async {
          if (!req.url.path.endsWith('/episodes')) {
            return http.Response('not found', 404);
          }
          final int offset =
              int.parse(req.url.queryParameters['offset'] ?? '0');
          offsets.add(offset);
          // 第一页两条全是非整数 sort（过滤后为空），第二页才是正篇第 3 话。
          final List<Map<String, Object?>> page = offset == 0
              ? <Map<String, Object?>>[
                  <String, Object?>{'sort': 0.5, 'name': 'SP1'},
                  <String, Object?>{'sort': 1.5, 'name': 'SP2'},
                ]
              : <Map<String, Object?>>[
                  <String, Object?>{'sort': 3, 'name': '第三话'},
                ];
          return http.Response.bytes(
            utf8.encode(
                jsonEncode(<String, Object?>{'data': page, 'total': 3})),
            200,
          );
        }),
      );
      addTearDown(bangumi.close);

      final List<BangumiEpisodeInfo> episodes =
          await bangumi.fetchSubjectEpisodes('100');
      expect(offsets, <int>[0, 2],
          reason: 'offset 按原始返回条数推进——按过滤后长度推进会在全滤页上'
              '提前终止，丢掉后面的正常页');
      expect(episodes.single.episodeNumber, 3);
    });
  });
}
