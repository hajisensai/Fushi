import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/alias_cache.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/collection_poster_store.dart';
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

  group('groupLibrary 分组规则', () {
    test('DB 合集聚组：displayTitle 用合集名，跨目录也聚', () async {
      final VideoBookRow a = await seed(
        bookUid: 'video/c1',
        videoPath: p.join('anime', 'DirA', 'Foo - 01.mkv'),
      );
      final VideoBookRow b = await seed(
        bookUid: 'video/c2',
        videoPath: p.join('anime', 'DirB', 'Foo - 02.mkv'),
      );
      final int cid =
          await db.createMediaCollection('我的合集', collectionType: 'playlist');
      await db.addToCollection(cid, 'video', 'video/c1');
      await db.addToCollection(cid, 'video', 'video/c2');

      final List<ScrapeGroup> groups =
          await build().groupLibrary(<VideoBookRow>[a, b]);
      expect(groups, hasLength(1));
      expect(groups.first.collectionId, cid);
      expect(groups.first.displayTitle, '我的合集');
      expect(groups.first.members.map((VideoBookRow r) => r.bookUid),
          <String>['video/c1', 'video/c2']);
      expect(groups.first.parsed, isNotNull);
    });

    test('同目录同标题散集聚成一组；不同目录不聚', () async {
      final VideoBookRow e1 = await seed(
        bookUid: 'video/t1',
        videoPath: p.join('lib', '高木同学', '[组] 高木同学 - 01.mkv'),
      );
      final VideoBookRow e2 = await seed(
        bookUid: 'video/t2',
        videoPath: p.join('lib', '高木同学', '[组] 高木同学 - 02.mkv'),
      );
      final VideoBookRow other = await seed(
        bookUid: 'video/t3',
        videoPath: p.join('lib2', '高木同学', '[组] 高木同学 - 01.mkv'),
      );
      final List<ScrapeGroup> groups =
          await build().groupLibrary(<VideoBookRow>[e1, e2, other]);
      expect(groups, hasLength(2));
      expect(groups[0].members.map((VideoBookRow r) => r.bookUid),
          <String>['video/t1', 'video/t2']);
      expect(groups[0].displayTitle, '高木同学');
      expect(groups[0].collectionId, isNull);
      expect(groups[1].members.single.bookUid, 'video/t3');
    });

    test('单本成组；解析不出标题也单本成组（parsed=null）', () async {
      final VideoBookRow solo = await seed(
        bookUid: 'video/solo',
        videoPath: p.join('lib', '孤独摇滚', '孤独摇滚 - 01.mkv'),
      );
      final VideoBookRow noTitle = await seed(
        bookUid: 'video/no-title',
        videoPath: p.join('Downloads', 'VID_20260701.mkv'),
        title: '设备录像',
      );
      final List<ScrapeGroup> groups =
          await build().groupLibrary(<VideoBookRow>[solo, noTitle]);
      expect(groups, hasLength(2));
      expect(groups[0].members.single.bookUid, 'video/solo');
      expect(groups[1].members.single.bookUid, 'video/no-title');
      expect(groups[1].parsed, isNull);
      expect(groups[1].displayTitle, '设备录像', reason: '无解析标题回退书名展示');
    });
  });

  test('合集组 high：海报只落合集级封面，全部成员抽帧封面原值不动', () async {
    // 两集各自预置「抽帧封面」旧值——断言刮削后原值仍在（用户拍板：每集保留抽帧）。
    final String frame1 = p.join(tmp.path, 'frame_c1.jpg');
    final String frame2 = p.join(tmp.path, 'frame_c2.jpg');
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/c1'),
      title: const Value('Foo 01'),
      videoPath: Value(p.join('lib', 'Foo', 'Foo - 01.mkv')),
      coverPath: Value(frame1),
    ));
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/c2'),
      title: const Value('Foo 02'),
      videoPath: Value(p.join('lib2', 'Foo', 'Foo - 02.mkv')),
      coverPath: Value(frame2),
    ));
    final int cid =
        await db.createMediaCollection('Foo 合集', collectionType: 'playlist');
    await db.addToCollection(cid, 'video', 'video/c1');
    await db.addToCollection(cid, 'video', 'video/c2');
    final VideoBookRow e1 = (await repo.getByBookUid('video/c1'))!;
    final VideoBookRow e2 = (await repo.getByBookUid('video/c2'))!;

    int searchCalls = 0;
    final BangumiClient counting = BangumiClient(
      client: MockClient((http.Request req) async {
        searchCalls++;
        return http.Response(
          _bangumiBody(id: 42, name: 'Foo'),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    final List<BatchScrapeProgress> events = await build(bangumi: counting)
        .scrapeLibrary(<VideoBookRow>[e1, e2]).toList();

    expect(events, hasLength(1), reason: '合集两集一组只 yield 一条进度');
    expect(searchCalls, 1, reason: '整组只搜索一次');
    final BatchScrapeProgress event = events.single;
    expect(event.group.collectionId, cid);
    expect(event.outcome, isA<ScrapeApplied>());
    expect(event.coverableUids, isEmpty, reason: '合集组不再逐成员分发，coverableUids 恒空');

    // 海报只落 collections/collection_<id>.jpg。
    final File poster = CollectionPosterStore(tmp).fileFor(cid);
    expect(poster.existsSync(), isTrue);
    expect((event.outcome as ScrapeApplied).coverPath, poster.path);
    expect(poster.readAsBytesSync(), _fakePng);

    // 成员书 coverPath 原值不动、成员 meta 未被写入。
    expect((await repo.getByBookUid('video/c1'))!.coverPath, frame1);
    expect((await repo.getByBookUid('video/c2'))!.coverPath, frame2);
    expect(await coverMeta.get('video/c1'), isNull);
    expect(await coverMeta.get('video/c2'), isNull);

    // 合集级 meta：collection:<id> scraped。
    final CoverMeta? meta =
        await coverMeta.get(CollectionPosterStore.metaKey(cid));
    expect(meta!.origin, CoverOrigin.scraped);
    expect(meta.entryId, '42');
    // 别名缓存照写（key=解析标题）。
    expect(await aliasCache.get('Foo'), isNotNull);
  });

  test('合集组保护线走 collection:<id> meta：scraped 不重刮、成员 meta 无关', () async {
    final VideoBookRow e1 = await seed(
      bookUid: 'video/pc1',
      videoPath: p.join('lib', 'Foo', 'Foo - 01.mkv'),
    );
    final int cid =
        await db.createMediaCollection('Foo', collectionType: 'playlist');
    await db.addToCollection(cid, 'video', 'video/pc1');
    await coverMeta.set(
      CollectionPosterStore.metaKey(cid),
      const CoverMeta(origin: CoverOrigin.scraped),
    );

    final List<BatchScrapeProgress> events =
        await build().scrapeLibrary(<VideoBookRow>[e1]).toList();
    expect(events, hasLength(1));
    final ScrapeOutcome outcome = events.single.outcome;
    expect(outcome, isA<ScrapeSkippedProtected>());
    expect((outcome as ScrapeSkippedProtected).origin, CoverOrigin.scraped);
    expect(CollectionPosterStore(tmp).fileFor(cid).existsSync(), isFalse);
  });

  test('目录多成员组（散集、无 DB 合集）→ 整组跳过，成员不动、零网络', () async {
    final VideoBookRow e1 = await seed(
      bookUid: 'video/d1',
      videoPath: p.join('lib', 'Foo', 'Foo - 01.mkv'),
    );
    final VideoBookRow e2 = await seed(
      bookUid: 'video/d2',
      videoPath: p.join('lib', 'Foo', 'Foo - 02.mkv'),
    );
    int searchCalls = 0;
    final BangumiClient counting = BangumiClient(
      client: MockClient((http.Request req) async {
        searchCalls++;
        return http.Response(
          _bangumiBody(id: 42, name: 'Foo'),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    final List<BatchScrapeProgress> events = await build(bangumi: counting)
        .scrapeLibrary(<VideoBookRow>[e1, e2]).toList();
    expect(events, hasLength(1));
    final ScrapeOutcome outcome = events.single.outcome;
    expect(outcome, isA<ScrapeSkippedDirectoryGroup>());
    expect((outcome as ScrapeSkippedDirectoryGroup).memberCount, 2);
    expect(events.single.coverableUids, isEmpty);
    expect(searchCalls, 0, reason: '跳过组不发起任何网络请求');
    expect((await repo.getByBookUid('video/d1'))!.coverPath, isNull);
    expect((await repo.getByBookUid('video/d2'))!.coverPath, isNull);
  });

  test('单本组 manual 保护 → skippedProtected', () async {
    final VideoBookRow solo = await seed(
      bookUid: 'video/solo_p',
      videoPath: p.join('anime', '进击的巨人', '进击的巨人 - 01.mkv'),
    );
    await coverMeta.set(
        'video/solo_p', const CoverMeta(origin: CoverOrigin.manual));
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
        await svc.scrapeLibrary(<VideoBookRow>[solo]).toList();
    expect(events, hasLength(1));
    final ScrapeOutcome outcome = events.single.outcome;
    expect(outcome, isA<ScrapeSkippedProtected>());
    expect((outcome as ScrapeSkippedProtected).origin, CoverOrigin.manual);
    expect((await repo.getByBookUid('video/solo_p'))!.coverPath, isNull);
  });

  test('单本组 high → 照旧落该书封面（原有能力不变）', () async {
    final VideoBookRow solo = await seed(
      bookUid: 'video/solo_h',
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
    final List<BatchScrapeProgress> events =
        await svc.scrapeLibrary(<VideoBookRow>[solo]).toList();
    expect(events, hasLength(1));
    expect(events.single.outcome, isA<ScrapeApplied>());
    expect(events.single.coverableUids, <String>['video/solo_h']);
    final VideoBookRow updated = (await repo.getByBookUid('video/solo_h'))!;
    expect(updated.coverPath, isNotNull);
    expect(File(updated.coverPath!).existsSync(), isTrue);
    expect((await coverMeta.get('video/solo_h'))!.origin, CoverOrigin.scraped);
  });

  test('合集组 medium → 一条 needsConfirm、不落盘、coverableUids 空', () async {
    // 年份差 ≥2（-0.20）+ 集数超总集数（-0.15）压到 medium 带。
    final VideoBookRow e1 = await seed(
      bookUid: 'video/m1',
      videoPath: p.join('lib', '进击的巨人 (2020)', '进击的巨人 - 04.mkv'),
    );
    final VideoBookRow e2 = await seed(
      bookUid: 'video/m2',
      videoPath: p.join('lib', '进击的巨人 (2020)', '进击的巨人 - 05.mkv'),
    );
    final int cid =
        await db.createMediaCollection('进击的巨人', collectionType: 'playlist');
    await db.addToCollection(cid, 'video', 'video/m1');
    await db.addToCollection(cid, 'video', 'video/m2');
    final PosterScraperService svc = build(
      offline: offlineWith(const OfflineAnimeRecord(
        title: '进击的巨人',
        type: ScrapeEntryType.tv,
        episodes: 3,
        year: 2013,
        picture: 'https://img/aot.png',
        sourceId: 'mal/16498',
      )),
    );
    final List<BatchScrapeProgress> events =
        await svc.scrapeLibrary(<VideoBookRow>[e1, e2]).toList();
    expect(events, hasLength(1));
    final BatchScrapeProgress event = events.single;
    expect(event.group.collectionId, cid);
    expect(event.outcome, isA<ScrapeNeedsConfirm>());
    final ScrapeNeedsConfirm confirm = event.outcome as ScrapeNeedsConfirm;
    expect(confirm.candidates.single.confidence, MatchConfidence.medium);
    expect(event.coverableUids, isEmpty);
    // 不落盘：无合集海报、成员封面不动。
    expect(CollectionPosterStore(tmp).fileFor(cid).existsSync(), isFalse);
    expect((await repo.getByBookUid('video/m1'))!.coverPath, isNull);
    expect((await repo.getByBookUid('video/m2'))!.coverPath, isNull);
  });

  test('合集组 sidecar：首成员目录 poster.jpg → 设为合集封面，成员不动', () async {
    final Directory lib = await Directory.systemTemp.createTemp('sidecar_col_');
    addTearDown(() async {
      if (await lib.exists()) await lib.delete(recursive: true);
    });
    final File video = File(p.join(lib.path, 'My Show - 01.mkv'));
    await video.writeAsBytes(<int>[0, 1, 2, 3]);
    await File(p.join(lib.path, 'poster.jpg')).writeAsBytes(_fakePng);
    final VideoBookRow e1 = await seed(
      bookUid: 'video/sc1',
      videoPath: video.path,
    );
    final int cid =
        await db.createMediaCollection('My Show', collectionType: 'playlist');
    await db.addToCollection(cid, 'video', 'video/sc1');

    final List<BatchScrapeProgress> events = await build(enableSidecar: true)
        .scrapeLibrary(<VideoBookRow>[e1]).toList();
    expect(events, hasLength(1));
    final ScrapeOutcome outcome = events.single.outcome;
    expect(outcome, isA<ScrapeApplied>());
    expect((outcome as ScrapeApplied).origin, CoverOrigin.sidecar);
    final File poster = CollectionPosterStore(tmp).fileFor(cid);
    expect(poster.existsSync(), isTrue);
    expect(poster.readAsBytesSync(), _fakePng);
    expect((await repo.getByBookUid('video/sc1'))!.coverPath, isNull,
        reason: '成员书封面不动');
    expect(
      (await coverMeta.get(CollectionPosterStore.metaKey(cid)))!.origin,
      CoverOrigin.sidecar,
    );
  });

  test('applyCandidateToBook 单本：下载落封面 + updateCover + scraped meta + alias',
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
    await svc.applyCandidateToBook(
      bookUid: 'video/manual_apply',
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

  test('applyCandidateToCollection：海报落 collections/、meta 记 collection:<id>',
      () async {
    final PosterScraperService svc = build();
    const ScrapeCandidate candidate = ScrapeCandidate(
      source: ScrapeSource.bangumi,
      entryId: '777',
      title: 'Y',
      posterUrl: 'https://img/y.png',
    );
    final String path = await svc.applyCandidateToCollection(
      collectionId: 12,
      candidate: candidate,
      aliasKey: 'Y',
    );
    final File poster = CollectionPosterStore(tmp).fileFor(12);
    expect(path, poster.path);
    expect(poster.existsSync(), isTrue);
    expect(poster.readAsBytesSync(), _fakePng);
    final CoverMeta? meta =
        await coverMeta.get(CollectionPosterStore.metaKey(12));
    expect(meta!.origin, CoverOrigin.scraped);
    expect(meta.source, ScrapeSource.bangumi);
    expect(meta.entryId, '777');
    expect((await aliasCache.get('Y'))!.$2, '777');
  });

  test('批量：单组网络异常记 failed 但不中断整批', () async {
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
    expect(events, hasLength(2), reason: '不同目录不同标题 → 两个组');
    expect(events[0].outcome, isA<ScrapeFailed>());
    expect(events[0].group.members.single.bookUid, 'video/e1');
    expect(events[1].outcome, isA<ScrapeFailed>());
    expect(events[1].group.members.single.bookUid, 'video/e2');
  });
}
