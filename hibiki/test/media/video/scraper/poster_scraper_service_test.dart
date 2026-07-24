import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/alias_cache.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/offline_index.dart';
import 'package:hibiki/src/media/video/scraper/poster_downloader.dart';
import 'package:hibiki/src/media/video/scraper/poster_scraper_service.dart';
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

/// 构造一个 Bangumi `/v0/search/subjects` 响应体（单条命中）。
String _bangumiBody({
  required int id,
  required String name,
  String? nameCn,
}) =>
    jsonEncode(<String, Object?>{
      'data': <Object?>[
        <String, Object?>{
          'id': id,
          'name': name,
          if (nameCn != null) 'name_cn': nameCn,
          'images': <String, Object?>{'large': 'https://img/b$id.png'},
          'platform': 'TV',
          'eps': 12,
          'date': '2020-01-01',
          'score': 8.0,
        },
      ],
    });

MockClient _pngClient() => MockClient((http.Request req) async {
      return http.Response.bytes(
        _fakePng,
        200,
        headers: const <String, String>{'content-type': 'image/png'},
      );
    });

void main() {
  late HibikiDatabase db;
  late VideoBookRepository repo;
  late Directory tmp;
  late CoverMetaStore coverMeta;
  late AliasCache aliasCache;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    tmp = await Directory.systemTemp.createTemp('poster_scraper_svc_');
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
    String title = 'seed',
  }) async {
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(title),
      videoPath: Value(videoPath),
    ));
    return (await repo.getByBookUid(bookUid))!;
  }

  OfflineIndex offlineWith(OfflineAnimeRecord record) =>
      OfflineIndex(<OfflineAnimeRecord>[record]);

  PosterScraperService build({
    OfflineIndex? offline,
    BangumiClient? bangumi,
    bool enableSidecar = false,
  }) =>
      PosterScraperService(
        repository: repo,
        coverMetaStore: coverMeta,
        aliasCache: aliasCache,
        bangumiClient: bangumi ??
            BangumiClient(
              client: MockClient(
                (http.Request req) async => http.Response(
                  _bangumiBody(id: 1, name: 'unused'),
                  200,
                  headers: const <String, String>{
                    'content-type': 'application/json'
                  },
                ),
              ),
            ),
        posterDownloader: PosterDownloader(client: _pngClient()),
        offlineIndex: offline,
        enableSidecar: enableSidecar,
        coversDirectory: tmp,
      );

  test('远端/流媒体路径不参与刮削 → notEligible', () async {
    final VideoBookRow book = await seed(
      bookUid: 'video/remote',
      videoPath: 'https://host/stream.m3u8',
    );
    final ScrapeOutcome outcome = await build().scrapeOne(book);
    expect(outcome, isA<ScrapeNotEligible>());
  });

  test('目录候选出 title、文件候选出 episode（合并解析）', () {
    final PosterScraperService svc = build();
    final ParsedMediaName? parsed = svc.parseForPath(
      p.join('anime', '进击的巨人 第三季', '[组] 进击的巨人 - 04 [1080p].mkv'),
    );
    expect(parsed, isNotNull);
    expect(parsed!.title, '进击的巨人');
    expect(parsed.season, 3, reason: '季度来自目录候选');
    expect(parsed.episode, 4, reason: '集数来自文件候选');
  });

  test('解析不出标题 → skippedNoTitle', () async {
    final VideoBookRow book = await seed(
      bookUid: 'video/dev',
      videoPath: p.join('Downloads', 'VID_20260701.mkv'),
    );
    final ScrapeOutcome outcome = await build().scrapeOne(book);
    expect(outcome, isA<ScrapeSkippedNoTitle>());
  });

  test('offline high 自动应用：落封面 + 写 scraped meta + 写别名', () async {
    final VideoBookRow book = await seed(
      bookUid: 'video/aot',
      videoPath: p.join('anime', '进击的巨人', '进击的巨人 - 04.mkv'),
    );
    final PosterScraperService svc = build(
      offline: offlineWith(const OfflineAnimeRecord(
        title: '进击的巨人',
        synonyms: <String>['Attack on Titan'],
        type: ScrapeEntryType.tv,
        episodes: 25,
        year: 2013,
        picture: 'https://img/aot.png',
        sourceId: 'myanimelist.net/anime/16498',
      )),
    );

    final ScrapeOutcome outcome = await svc.scrapeOne(book);
    expect(outcome, isA<ScrapeApplied>());
    final ScrapeApplied applied = outcome as ScrapeApplied;
    expect(applied.origin, CoverOrigin.scraped);
    expect(applied.decision!.confidence, MatchConfidence.high);

    // 封面落库 + 文件存在。
    final VideoBookRow updated = (await repo.getByBookUid('video/aot'))!;
    expect(updated.coverPath, applied.coverPath);
    expect(File(applied.coverPath).existsSync(), isTrue);

    // scraped 元数据。
    final CoverMeta? meta = await coverMeta.get('video/aot');
    expect(meta!.origin, CoverOrigin.scraped);
    expect(meta.source, ScrapeSource.offlineDb);
    expect(meta.entryId, 'myanimelist.net/anime/16498');

    // 别名缓存写入（key=解析标题）。
    final (ScrapeSource, String)? alias = await aliasCache.get('进击的巨人');
    expect(alias, isNotNull);
    expect(alias!.$1, ScrapeSource.offlineDb);
  });

  test('别名命中短路：即便候选标题不同也强制应用记住的 entryId', () async {
    final VideoBookRow book = await seed(
      bookUid: 'video/alias',
      videoPath: p.join('anime', '某作品', '某作品 - 01.mkv'),
    );
    // 预先记一条纠错：某作品 → bangumi/777。
    await aliasCache.put('某作品', ScrapeSource.bangumi, '777');

    // Bangumi 返回 id=777 但标题完全不同（正常打分会是 low）。
    final BangumiClient bangumi = BangumiClient(
      client: MockClient(
        (http.Request req) async => http.Response(
          _bangumiBody(id: 777, name: 'Totally Different Title'),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        ),
      ),
    );
    final ScrapeOutcome outcome = await build(bangumi: bangumi).scrapeOne(book);
    expect(outcome, isA<ScrapeApplied>());
    final CoverMeta? meta = await coverMeta.get('video/alias');
    expect(meta!.source, ScrapeSource.bangumi);
    expect(meta.entryId, '777');
  });

  test('sidecar 直取：同目录 poster.jpg → 复制为封面、origin=sidecar', () async {
    final Directory lib = await Directory.systemTemp.createTemp('sidecar_lib_');
    addTearDown(() async {
      if (await lib.exists()) await lib.delete(recursive: true);
    });
    final File video = File(p.join(lib.path, 'My Show - 01.mkv'));
    await video.writeAsBytes(<int>[0, 1, 2, 3]);
    await File(p.join(lib.path, 'poster.jpg')).writeAsBytes(_fakePng);

    final VideoBookRow book = await seed(
      bookUid: 'video/sidecar',
      videoPath: video.path,
    );
    final ScrapeOutcome outcome =
        await build(enableSidecar: true).scrapeOne(book);
    expect(outcome, isA<ScrapeApplied>());
    expect((outcome as ScrapeApplied).origin, CoverOrigin.sidecar);

    final VideoBookRow updated = (await repo.getByBookUid('video/sidecar'))!;
    expect(File(updated.coverPath!).existsSync(), isTrue);
    expect(File(updated.coverPath!).readAsBytesSync(), _fakePng);
    final CoverMeta? meta = await coverMeta.get('video/sidecar');
    expect(meta!.origin, CoverOrigin.sidecar);
  });

  test('applyHighConfidence=false：high 也只返回 needsConfirm，不落盘', () async {
    final VideoBookRow book = await seed(
      bookUid: 'video/preview',
      videoPath: p.join('anime', '进击的巨人', '进击的巨人 - 04.mkv'),
    );
    final PosterScraperService svc = build(
      offline: offlineWith(const OfflineAnimeRecord(
        title: '进击的巨人',
        type: ScrapeEntryType.tv,
        episodes: 25,
        picture: 'https://img/aot.png',
        sourceId: 'mal/16498',
      )),
    );
    final ScrapeOutcome outcome =
        await svc.scrapeOne(book, applyHighConfidence: false);
    expect(outcome, isA<ScrapeNeedsConfirm>());
    // 未落盘：封面路径仍空、无 meta。
    expect((await repo.getByBookUid('video/preview'))!.coverPath, isNull);
    expect(await coverMeta.get('video/preview'), isNull);
  });

  test('批量跳过 manual 封面，处理 autoFrame 无记录的书', () async {
    final VideoBookRow manualBook = await seed(
      bookUid: 'video/manual',
      videoPath: p.join('anime', '进击的巨人', '进击的巨人 - 01.mkv'),
    );
    final VideoBookRow autoBook = await seed(
      bookUid: 'video/auto',
      videoPath: p.join('anime', '进击的巨人', '进击的巨人 - 02.mkv'),
    );
    await coverMeta.set(
        'video/manual', const CoverMeta(origin: CoverOrigin.manual));

    final PosterScraperService svc = build(
      offline: offlineWith(const OfflineAnimeRecord(
        title: '进击的巨人',
        type: ScrapeEntryType.tv,
        episodes: 25,
        picture: 'https://img/aot.png',
        sourceId: 'mal/16498',
      )),
    );
    final List<BatchScrapeProgress> events =
        await svc.scrapeLibrary(<VideoBookRow>[manualBook, autoBook]).toList();
    expect(events, hasLength(2));

    final ScrapeOutcome manualOutcome = events
        .firstWhere((BatchScrapeProgress e) => e.book.bookUid == 'video/manual')
        .outcome;
    expect(manualOutcome, isA<ScrapeSkippedProtected>());
    expect(
        (manualOutcome as ScrapeSkippedProtected).origin, CoverOrigin.manual);

    final ScrapeOutcome autoOutcome = events
        .firstWhere((BatchScrapeProgress e) => e.book.bookUid == 'video/auto')
        .outcome;
    expect(autoOutcome, isA<ScrapeApplied>());
    // manual 封面不被覆盖。
    expect((await repo.getByBookUid('video/manual'))!.coverPath, isNull);
  });

  test('applyCandidateToBooks 单本：下载落封面 + updateCover + scraped meta + alias',
      () async {
    await seed(
      bookUid: 'video/manual_apply',
      videoPath: p.join('anime', 'X', 'X - 01.mkv'),
    );
    final PosterScraperService svc = build();
    const ScrapeCandidate candidate = ScrapeCandidate(
      source: ScrapeSource.bangumi,
      entryId: '999',
      title: 'X',
      posterUrl: 'https://img/x.png',
    );
    await svc.applyCandidateToBooks(
      bookUids: <String>['video/manual_apply'],
      candidate: candidate,
      aliasKey: 'X',
    );
    final VideoBookRow updated =
        (await repo.getByBookUid('video/manual_apply'))!;
    expect(updated.coverPath, isNotNull);
    expect(File(updated.coverPath!).existsSync(), isTrue);
    final CoverMeta? meta = await coverMeta.get('video/manual_apply');
    expect(meta!.source, ScrapeSource.bangumi);
    expect((await aliasCache.get('X'))!.$2, '999');
  });

  test('批量：单本网络异常记 failed 但不中断整批', () async {
    final VideoBookRow b1 = await seed(
      bookUid: 'video/e1',
      videoPath: p.join('anime', 'Foo', 'Foo - 01.mkv'),
    );
    final VideoBookRow b2 = await seed(
      bookUid: 'video/e2',
      videoPath: p.join('anime', 'Bar', 'Bar - 01.mkv'),
    );
    // Bangumi 恒 500 → search 抛 ScrapeNetworkException；无离线、无 TMDB。
    final BangumiClient failing = BangumiClient(
      client: MockClient((http.Request req) async => http.Response('err', 500)),
    );
    final List<BatchScrapeProgress> events = await build(bangumi: failing)
        .scrapeLibrary(<VideoBookRow>[b1, b2]).toList();
    expect(events, hasLength(2));
    expect(events[0].outcome, isA<ScrapeFailed>());
    expect(events[1].outcome, isA<ScrapeFailed>());
  });
}
