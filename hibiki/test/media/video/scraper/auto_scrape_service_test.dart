/// 视频条目自动刮削（取代页头「批量匹配海报」按钮）端到端单测。
///
/// 覆盖真实链路：书单 → 过滤（本地 / 未刮 / 未尝试）→ [PosterScraperService]
/// 匹配落封面 → Bangumi 详情 → `video_scrape_meta` 落库 → 仓库读回领域对象。
/// 全部走内存 DB + MockClient，无真实网络。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/alias_cache.dart';
import 'package:hibiki/src/media/video/scraper/auto_scrape_service.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/poster_downloader.dart';
import 'package:hibiki/src/media/video/scraper/poster_scraper_service.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

final List<int> _fakePng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x01, 0x02, 0x03,
];

/// 搜索响应：单条命中「进击的巨人」（与文件名同名 → high 置信度）。
String _searchBody() => jsonEncode(<String, Object?>{
      'data': <Object?>[
        <String, Object?>{
          'id': 12345,
          'name': '進撃の巨人',
          'name_cn': '进击的巨人',
          'images': <String, Object?>{'large': 'https://img/aot.png'},
          'platform': 'TV',
          'eps': 25,
          'date': '2013-04-07',
          'score': 8.9,
        },
      ],
    });

/// 详情响应：全量条目资料。
String _subjectBody() => jsonEncode(<String, Object?>{
      'id': 12345,
      'name': '進撃の巨人',
      'name_cn': '进击的巨人',
      'summary': '巨人吃人的故事。',
      'date': '2013-04-07',
      'eps': 25,
      'total_episodes': 25,
      'rating': <String, Object?>{'score': 8.9, 'total': 30000},
      'tags': <Object?>[
        <String, Object?>{'name': '奇幻', 'count': 500},
      ],
      'infobox': <Object?>[
        <String, Object?>{'key': '导演', 'value': '荒木哲郎'},
      ],
    });

void main() {
  late HibikiDatabase db;
  late VideoBookRepository repo;
  late Directory tmp;

  /// 记录每类请求次数，用来断言「详情只拉一次」「关闸后零请求」。
  late int searchCalls;
  late int subjectCalls;

  setUp(() async {
    // 显式开 foreign_keys：`forTesting` 直接吃裸 NativeDatabase，不走 _openDb 的
    // PRAGMA 设置，默认 FK 是关的。真实 app 恒开，cascade 断言必须在同样语义下跑
    // 才有意义（否则「删视频不清资料行」这种真缺陷会被测试放过）。
    db = HibikiDatabase.forTesting(NativeDatabase.memory(
      setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
    ));
    repo = VideoBookRepository(db);
    tmp = await Directory.systemTemp.createTemp('auto_scrape_');
    searchCalls = 0;
    subjectCalls = 0;
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
    return (await repo.getByBookUid(bookUid))!;
  }

  /// 一个按端点分流的 Bangumi mock：POST=搜索，GET=条目详情。
  BangumiClient bangumi() => BangumiClient(
        client: MockClient((http.Request req) async {
          final bool isSubject =
              req.method == 'GET' && req.url.path.startsWith('/v0/subjects/');
          if (isSubject) {
            subjectCalls++;
            return http.Response.bytes(
              utf8.encode(_subjectBody()),
              200,
              headers: const <String, String>{
                'content-type': 'application/json'
              },
            );
          }
          searchCalls++;
          return http.Response.bytes(
            utf8.encode(_searchBody()),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }),
      );

  PosterScraperService buildService() => PosterScraperService(
        repository: repo,
        coverMetaStore: CoverMetaStore(tmp),
        aliasCache: AliasCache(tmp),
        bangumiClient: bangumi(),
        posterDownloader: PosterDownloader(
          client: MockClient((http.Request req) async => http.Response.bytes(
                _fakePng,
                200,
                headers: const <String, String>{'content-type': 'image/png'},
              )),
        ),
        enableSidecar: false,
        coversDirectory: tmp,
      );

  VideoScrapeAutoService buildAuto({bool Function()? isEnabled}) =>
      VideoScrapeAutoService(
        repository: repo,
        serviceFactory: () async => buildService(),
        isEnabled: isEnabled,
        perBookDelay: Duration.zero,
      );

  String pathFor(int episode) => p.join(
        'anime',
        '进击的巨人',
        '进击的巨人 - ${episode.toString().padLeft(2, '0')}.mkv',
      );

  test('自动刮削把 Bangumi 条目资料落进 video_scrape_meta（封面 + 全量资料）', () async {
    final VideoBookRow book =
        await seed(bookUid: 'video/aot1', videoPath: pathFor(1));

    await buildAuto().sweep(<VideoBookRow>[book]);

    final ScrapeMetadata? meta = await repo.scrapeMetadata('video/aot1');
    expect(meta, isNotNull, reason: '自动刮削后应有条目资料行');
    expect(meta!.source, ScrapeSource.bangumi);
    expect(meta.subjectId, '12345');
    expect(meta.title, '进击的巨人');
    expect(meta.originalTitle, '進撃の巨人');
    expect(meta.summary, '巨人吃人的故事。');
    expect(meta.airDate, '2013-04-07');
    expect(meta.rating, 8.9);
    expect(meta.ratingCount, 30000);
    expect(meta.episodeCount, 25);
    expect(meta.tags.single.name, '奇幻');
    expect(meta.infobox.single.key, '导演');
    expect(meta.infobox.single.value, '荒木哲郎');
    expect(meta.detailUrl, 'https://bgm.tv/subject/12345');

    // 封面也照旧落了（资料层不取代封面层）。
    final VideoBookRow updated = (await repo.getByBookUid('video/aot1'))!;
    expect(File(updated.coverPath!).existsSync(), isTrue);
  });

  test('远端/流媒体书不参与：不发任何请求、不落资料', () async {
    final VideoBookRow remote = await seed(
      bookUid: 'video/remote',
      videoPath: 'https://example.com/stream.m3u8',
    );

    await buildAuto().sweep(<VideoBookRow>[remote]);

    expect(searchCalls, 0);
    expect(subjectCalls, 0);
    expect(await repo.scrapeMetadata('video/remote'), isNull);
  });

  test('已有资料的书不重刮（DB 里已有行 → 直接跳过，零请求）', () async {
    final VideoBookRow book =
        await seed(bookUid: 'video/done', videoPath: pathFor(3));
    await repo.saveScrapeMetadata(
      'video/done',
      const ScrapeMetadata(
        source: ScrapeSource.bangumi,
        subjectId: '999',
        title: '早就刮过了',
      ),
    );

    await buildAuto().sweep(<VideoBookRow>[book]);

    expect(searchCalls, 0);
    expect(subjectCalls, 0);
    // 既有资料不被覆盖。
    expect((await repo.scrapeMetadata('video/done'))!.subjectId, '999');
  });

  test('同一部番的多集共享一次详情请求（详情缓存），不是每集一次', () async {
    final List<VideoBookRow> books = <VideoBookRow>[
      for (int i = 1; i <= 3; i++)
        await seed(bookUid: 'video/ep$i', videoPath: pathFor(i)),
    ];

    await buildAuto().sweep(books);

    expect(subjectCalls, 1, reason: '3 集同一条目，详情只拉一次');
    for (int i = 1; i <= 3; i++) {
      expect(
        (await repo.scrapeMetadata('video/ep$i'))!.subjectId,
        '12345',
        reason: '每集都要落到自己的资料行',
      );
    }
  });

  test('每本每进程只尝试一次：第二轮 sweep 不再重发请求', () async {
    final VideoBookRow book =
        await seed(bookUid: 'video/once', videoPath: pathFor(5));
    final VideoScrapeAutoService auto = buildAuto();

    await auto.sweep(<VideoBookRow>[book]);
    final int afterFirst = searchCalls;
    expect(afterFirst, greaterThan(0));

    await auto.sweep(<VideoBookRow>[book]);
    expect(searchCalls, afterFirst, reason: '已尝试过的书不该再发请求');
  });

  test('forget() 让用户「重新刮削」能真正重跑（清尝试记录 + 丢负缓存）', () async {
    final VideoBookRow book =
        await seed(bookUid: 'video/redo', videoPath: pathFor(6));
    final VideoScrapeAutoService auto = buildAuto();

    await auto.sweep(<VideoBookRow>[book]);
    final int afterFirst = searchCalls;

    // 模拟用户点「重新刮削」：删资料行 + forget。
    await repo.deleteScrapeMetadata('video/redo');
    auto.forget('video/redo');
    await auto.sweep(<VideoBookRow>[book]);

    expect(searchCalls, greaterThan(afterFirst), reason: '重新刮削应真的重发请求');
    expect(await repo.scrapeMetadata('video/redo'), isNotNull);
  });

  test('封面受保护（手动设过）的书仍然补条目资料，但封面不被覆盖', () async {
    final VideoBookRow book =
        await seed(bookUid: 'video/manual', videoPath: pathFor(7));
    await CoverMetaStore(tmp).set(
      'video/manual',
      const CoverMeta(origin: CoverOrigin.manual),
    );

    await buildAuto().sweep(<VideoBookRow>[book]);

    expect(
      await repo.scrapeMetadata('video/manual'),
      isNotNull,
      reason: '手动封面的书此前完全刮不到资料，这正是要修的洞',
    );
    expect(
      (await repo.getByBookUid('video/manual'))!.coverPath,
      isNull,
      reason: '手动封面绝不能被自动刮削覆盖',
    );
  });

  test('设置里关掉「自动刮削条目资料」→ 一个请求都不发、不落资料', () async {
    final VideoBookRow book =
        await seed(bookUid: 'video/off', videoPath: pathFor(11));

    await buildAuto(isEnabled: () => false).sweep(<VideoBookRow>[book]);

    expect(searchCalls, 0, reason: '总闸关掉后不得出网');
    expect(subjectCalls, 0);
    expect(await repo.scrapeMetadata('video/off'), isNull);
  });

  test('总闸每轮进场读一次：关→开之间不必重建服务', () async {
    final VideoBookRow book =
        await seed(bookUid: 'video/toggle', videoPath: pathFor(12));
    bool enabled = false;
    final VideoScrapeAutoService auto = buildAuto(isEnabled: () => enabled);

    await auto.sweep(<VideoBookRow>[book]);
    expect(await repo.scrapeMetadata('video/toggle'), isNull);

    enabled = true;
    await auto.sweep(<VideoBookRow>[book]);
    expect(
      await repo.scrapeMetadata('video/toggle'),
      isNotNull,
      reason: '开关打开后同一个服务实例下一轮就该开始刮',
    );
  });

  test('dispose 后不再继续刮（页面切走即停）', () async {
    final VideoBookRow book =
        await seed(bookUid: 'video/stop', videoPath: pathFor(8));
    final VideoScrapeAutoService auto = buildAuto();
    auto.dispose();

    await auto.sweep(<VideoBookRow>[book]);

    expect(searchCalls, 0);
    expect(await repo.scrapeMetadata('video/stop'), isNull);
  });

  test('dispose 立刻唤醒节流等待，不留 pending Timer（BUG-834 类孤儿 async）', () async {
    // 非零间隔：真机默认路径。sweep 会在第一本刮完后挂在节流等待上。
    final List<VideoBookRow> books = <VideoBookRow>[
      for (int i = 20; i <= 22; i++)
        await seed(bookUid: 'video/throttle$i', videoPath: pathFor(i)),
    ];
    final VideoScrapeAutoService auto = VideoScrapeAutoService(
      repository: repo,
      serviceFactory: () async => buildService(),
      perBookDelay: const Duration(seconds: 30),
    );

    final Future<void> running = auto.sweep(books);
    // 让第一本跑完并挂上 30s 节流等待。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    auto.dispose();

    // 若 dispose 不唤醒等待，这里要挂满 30s 才返回（测试超时即回归）。
    await running.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('dispose 后 sweep 应立刻收手，不该继续等节流定时器'),
    );
    expect(auto.isRunning, isFalse);
  });

  test('资料 JSON 列往返：标签/infobox 原样读回', () async {
    await seed(bookUid: 'video/roundtrip', videoPath: pathFor(9));
    await repo.saveScrapeMetadata(
      'video/roundtrip',
      const ScrapeMetadata(
        source: ScrapeSource.bangumi,
        subjectId: '7',
        title: '标题',
        tags: <ScrapeTag>[
          ScrapeTag(name: '日常', count: 12),
          ScrapeTag(name: '治愈'),
        ],
        infobox: <ScrapeInfoboxEntry>[
          ScrapeInfoboxEntry(key: '原作', value: '某某'),
        ],
      ),
    );

    final ScrapeMetadata meta = (await repo.scrapeMetadata('video/roundtrip'))!;
    expect(meta.tags.map((ScrapeTag t) => t.name), <String>['日常', '治愈']);
    expect(meta.tags.first.count, 12);
    expect(meta.tags[1].count, 0);
    expect(meta.infobox.single.key, '原作');
  });

  test('删视频 → FK cascade 连带清掉资料行（不留孤儿）', () async {
    await seed(bookUid: 'video/gone', videoPath: pathFor(10));
    await repo.saveScrapeMetadata(
      'video/gone',
      const ScrapeMetadata(
        source: ScrapeSource.bangumi,
        subjectId: '1',
        title: 't',
      ),
    );
    expect(await repo.scrapeMetadata('video/gone'), isNotNull);

    await db.deleteVideoBook('video/gone');

    expect(await repo.scrapeMetadata('video/gone'), isNull);
  });
}
