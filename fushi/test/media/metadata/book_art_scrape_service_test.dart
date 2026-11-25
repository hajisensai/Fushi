import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_art_scrape.dart';
import 'package:fushi/src/media/metadata/book_art_scrape_service.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart'
    show kBookScraperUserAgent;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart';
import 'package:fushi_engine/media/metadata/books/book_catalog.dart'
    show BookCatalogHttp;
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_client.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_rate_gates.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

/// 每卷封面刮削服务：离线 MangaBaka / Bangumi / 图片 CDN。
List<int> png(int width, int height, {int shade = 0}) => img.encodePng(
  img.Image(width: width, height: height)
    ..clear(img.ColorRgb8(shade, shade, shade)),
);

Map<String, Object?> mbSeries({
  int id = 100,
  String finalVolume = '3',
  String type = 'manga',
}) => <String, Object?>{
  'id': id,
  'state': 'active',
  'merged_with': null,
  'canonical_url': 'https://mangabaka.org/manga/$id/test',
  'title': 'Test Manga',
  'native_title': 'テスト漫画',
  'romanized_title': 'Tesuto Manga',
  'cover': <String, Object?>{
    'raw': <String, Object?>{
      'url': 'https://images.mangabaka.dev/cover/$id',
      'width': 1200,
      'height': 1800,
      'format': 'jpeg',
    },
  },
  'authors': <String>['Taro'],
  'artists': <String>['Taro'],
  'type': type,
  'content_rating': 'safe',
  'final_volume': finalVolume,
  'titles': <Object?>[],
};

Map<String, Object?> mbImage(
  int id,
  String index, {
  String type = 'volume',
  int width = 1200,
  int height = 1800,
}) => <String, Object?>{
  'id': id,
  'series_id': 100,
  'index': index,
  'index_numeric': num.parse(index),
  'type': type,
  'language': type == 'volume' ? 'ja' : null,
  'note': null,
  'content_rating': 'safe',
  'image': <String, Object?>{
    'raw': <String, Object?>{
      'url': 'https://images.mangabaka.dev/$type/$index',
      'width': width,
      'height': height,
      'format': 'jpeg',
    },
  },
};

http.Response json(Object body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const <String, String>{'content-type': 'application/json'},
);

http.Response page(List<Object?> data) => json(<String, Object?>{
  'status': 200,
  'data': data,
  'pagination': <String, Object?>{'count': data.length, 'next': null},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory thumbs;
  late BookArtStore store;
  late List<Uri> requests;
  late List<String> userAgents;

  /// 发给 AniList GraphQL 的请求体（JSON 解码后）。
  late List<Map<String, Object?>> aniListQueries;

  setUp(() async {
    BookArtStore.resetForTesting();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    thumbs = await Directory.systemTemp.createTemp('fushi_book_art_svc_');
    store = BookArtStore.of(thumbs);
    requests = <Uri>[];
    userAgents = <String>[];
    aniListQueries = <Map<String, Object?>>[];
  });

  tearDown(() async {
    BookArtStore.resetForTesting();
    await db.close();
    if (thumbs.existsSync()) await thumbs.delete(recursive: true);
  });

  Future<void> seed(String key, String title) => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: key,
      title: title,
      epubPath: '/nonexistent/$key.cbz',
      extractDir: '/nonexistent/$key',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1000,
      author: const Value<String?>('Taro'),
      format: const Value<String>('manga'),
    ),
  );

  /// AniList GraphQL 默认回答：搜不到、按 id 查无此条（不在测试里制造横幅）。
  http.Response aniListEmpty(Map<String, Object?> body) =>
      json(<String, Object?>{
        'data': <String, Object?>{
          'Page': <String, Object?>{'media': <Object?>[]},
          'Media': null,
        },
      });

  BookArtScrapeService service(
    Future<http.Response> Function(http.Request req) handler, {
    Future<void> Function(Duration)? wait,
    http.Response Function(Map<String, Object?> body)? aniList,
  }) {
    final MockClient client = MockClient((http.Request req) async {
      requests.add(req.url);
      if (req.url.host == 'graphql.anilist.co') {
        final Map<String, Object?> body =
            jsonDecode(req.body) as Map<String, Object?>;
        aniListQueries.add(body);
        return (aniList ?? aniListEmpty)(body);
      }
      userAgents.add(req.headers['User-Agent'] ?? '');
      return handler(req);
    });
    return BookArtScrapeService(
      database: db,
      store: store,
      client: client,
      catalogHttp: BookCatalogHttp(client: client, throttle: false),
      mangaBaka: MangaBakaClient(
        client: client,
        userAgent: kBookScraperUserAgent,
        gates: MangaBakaRateGates(),
        wait: wait ?? (Duration _) async {},
      ),
      now: () => DateTime.fromMillisecondsSinceEpoch(5000),
    );
  }

  /// 图片 CDN：MangaBaka / Bangumi 的图都回一张真 PNG。
  http.Response? image(http.Request req) {
    final String host = req.url.host;
    if (host == 'images.mangabaka.dev') {
      return http.Response.bytes(
        req.url.path.startsWith('/banner')
            ? png(48, 16, shade: 30)
            : png(12, 18, shade: 60),
        200,
        headers: const <String, String>{'content-type': 'image/png'},
      );
    }
    if (host == 's4.anilist.co') {
      return http.Response.bytes(
        png(57, 12, shade: 120),
        200,
        headers: const <String, String>{'content-type': 'image/png'},
      );
    }
    if (host == 'lain.bgm.tv') {
      return http.Response.bytes(
        png(10, 15, shade: 90),
        200,
        headers: const <String, String>{'content-type': 'image/png'},
      );
    }
    return null;
  }

  Future<http.Response> mangaBakaOk(http.Request req) async {
    final http.Response? img = image(req);
    if (img != null) return img;
    final String path = req.url.path;
    if (path == '/v1/series/search') {
      return page(<Object?>[mbSeries()]);
    }
    if (path == '/v1/series/100/images') {
      if (req.url.queryParameters['type'] == 'banner') {
        return page(<Object?>[
          mbImage(9, '1', type: 'banner', width: 1920, height: 600),
        ]);
      }
      return page(<Object?>[mbImage(1, '1'), mbImage(2, '2'), mbImage(3, '3')]);
    }
    return http.Response('unexpected ${req.url}', 500);
  }

  /// Bangumi 系列条目 7（搜索结果与按 id 取同一形状）。
  const Map<String, Object?> bangumiSeries7 = <String, Object?>{
    'id': 7,
    'name': 'テスト漫画',
    'name_cn': '',
    'platform': '漫画',
    'series': true,
    'nsfw': false,
    'volumes': 3,
    'infobox': <Object?>[
      <String, Object?>{'key': '作者', 'value': 'Taro'},
    ],
    'images': <String, Object?>{'large': 'https://lain.bgm.tv/s/7.jpg'},
  };

  /// Bangumi：系列条目 7 + 两本单行本。
  http.Response? bangumi(http.Request req) {
    if (req.url.host != 'api.bgm.tv') return null;
    final String path = req.url.path;
    if (path == '/v0/search/subjects') {
      return json(<String, Object?>{
        'data': <Object?>[bangumiSeries7],
      });
    }
    if (path == '/v0/subjects/7') return json(bangumiSeries7);
    if (path == '/v0/subjects/7/subjects') {
      return json(<Object?>[
        for (final int v in <int>[1, 2])
          <String, Object?>{
            'id': 70 + v,
            'name': 'テスト漫画 ($v)',
            'name_cn': '',
            'relation': '单行本',
            'type': 1,
            'images': <String, Object?>{
              'large': 'https://lain.bgm.tv/pic/cover/l/$v.jpg',
            },
          },
      ]);
    }
    return http.Response('unexpected ${req.url}', 404);
  }

  // BUG-5396：v83 起合集 epub 成员行 entryKey 是书 uid，不是 bookKey。合集入口
  // 曾把 entryKey 直接当 bookKey 用：一本书都认不出，结果面板只剩「0 / 0 / 0」，
  // 横幅也按 uid 去查刮削层，永远是空。
  test('合集成员按 uid 存：刮削认得出书、写入卷封面，横幅能按成员读回', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    await seed('legacy', 'テスト漫画 3');
    final String uid1 = (await db.resolveEpubBookUid('k1'))!;
    final String uid2 = (await db.resolveEpubBookUid('k2'))!;
    expect(uid1, isNot('k1'));
    final int collectionId = await db.createMediaCollection('テスト漫画');
    await db.addToCollection(collectionId, MediaKind.epub, uid1);
    await db.addToCollection(collectionId, MediaKind.epub, uid2);
    // v83 前的存量行（bookKey）照样认；远端透传行 / 非书成员跳过。
    await db.addToCollection(collectionId, MediaKind.epub, 'legacy');
    await db.addToCollection(collectionId, MediaKind.epub, 'remote-only');
    await db.addToCollection(collectionId, MediaKind.video, 'k1');

    expect(await collectionMemberBookKeys(db, collectionId), <String>[
      'k1',
      'k2',
      'legacy',
    ]);

    final BookArtScrapeService svc = service(mangaBakaOk);
    final BookArtRunResult result = await svc.run(
      await svc.collectionBookKeys(collectionId),
    );
    svc.close();

    expect(result.series, hasLength(1));
    expect(result.series.single.decision, BookArtDecision.accepted);
    expect(result.count(BookArtBookOutcome.written), 3);
    expect(store.hasCover('k1'), isTrue);
    expect(store.hasCover('k2'), isTrue);

    final CollectionArtScrape art = CollectionArtScrape(
      database: db,
      thumbnailsDirectory: thumbs,
      servicesEnabled: () => true,
      migrationReadonly: () => false,
    );
    final File? banner = await art.bannerFor(
      await db.getCollectionItems(collectionId),
    );
    expect(banner, isNotNull);
    expect(banner!.existsSync(), isTrue);
  });

  test('MangaBaka 命中：逐卷写入 + 横幅 + 署名标记；UA 不带用户信息', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    final BookArtScrapeService svc = service(mangaBakaOk);
    final BookArtRunResult result = await svc.run(<String>['k1', 'k2']);
    svc.close();

    expect(result.series, hasLength(1));
    final BookArtSeriesPlan plan = result.series.single;
    expect(plan.decision, BookArtDecision.accepted);
    expect(plan.source, BookArtSource.mangabaka);
    expect(result.count(BookArtBookOutcome.written), 2);
    expect(result.usesMangaBaka, isTrue);
    expect(store.hasCover('k1'), isTrue);
    expect(store.hasCover('k2'), isTrue);
    expect(
      store.recordFor('k2')!.coverUrl,
      'https://images.mangabaka.dev/volume/2',
    );
    expect(store.backdropForCollection(<String>['k1', 'k2']), isNotNull);
    // 两卷都够清晰：不去问 Bangumi。
    expect(requests.where((Uri u) => u.host == 'api.bgm.tv'), isEmpty);
    expect(userAgents.toSet(), <String>{kBookScraperUserAgent});
    expect(result.snapshots, hasLength(2));

    // 快照恢复 = 撤销：回到没刮过。
    for (final BookArtSnapshot s in result.snapshots.reversed) {
      await store.restore(s);
    }
    expect(store.hasCover('k1'), isFalse);
    expect(store.recordFor('k2'), isNull);
  });

  // BUG-5287：台版只有第 1 卷在 MangaBaka 上有中文封面；第 2 卷只有日文版封面，
  // 默认保留书里的封面，用户按系列改选「用 MangaBaka 封面」才用日文版。
  test('非日文版：本语言封面优先；缺卷默认保留书里的封面，可按系列改用原版封面并记住', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    await db.updateEpubBookLanguage('k1', 'zh-Hant');
    await db.updateEpubBookLanguage('k2', 'zh-TW');
    Future<http.Response> handler(http.Request req) async {
      if (req.url.path == '/v1/series/100/images' &&
          req.url.queryParameters['type'] == 'volume') {
        final Map<String, Object?> zh1 = mbImage(11, '1')
          ..['language'] = 'zh-tw'
          ..['image'] = <String, Object?>{
            'raw': <String, Object?>{
              'url': 'https://images.mangabaka.dev/volume/zh1',
              'width': 1200,
              'height': 1800,
              'format': 'jpeg',
            },
          };
        return page(<Object?>[mbImage(1, '1'), mbImage(2, '2'), zh1]);
      }
      return mangaBakaOk(req);
    }

    Future<BookArtSeriesPlan> scrape([
      Map<String, bool> choice = const <String, bool>{},
    ]) async {
      final BookArtScrapeService svc = service(handler);
      final BookArtRunResult result = await svc.run(
        <String>['k1', 'k2'],
        originalEditionCovers: choice,
        onlyPinnedGroups: choice.isNotEmpty,
      );
      svc.close();
      return result.series.single;
    }

    final BookArtSeriesPlan first = await scrape();
    expect(first.edition, 'zh');
    expect(first.originalEditionVolumes, 1);
    expect(first.originalEditionCovers, isFalse);
    expect(
      store.recordFor('k1')!.coverUrl,
      'https://images.mangabaka.dev/volume/zh1',
    );
    expect(store.hasCover('k2'), isFalse, reason: '不拿日文版封面盖掉书里的封面');
    expect(requests.where((Uri u) => u.host == 'api.bgm.tv'), isEmpty);

    final BookArtSeriesPlan use = await scrape(<String, bool>{
      first.seriesKey: true,
    });
    expect(use.originalEditionCovers, isTrue);
    expect(
      store.recordFor('k2')!.coverUrl,
      'https://images.mangabaka.dev/volume/2',
    );
    expect(store.recordFor('k2')!.coverFromOriginalEdition, isTrue);
    expect(store.recordFor('k1')!.coverFromOriginalEdition, isFalse);
    expect(store.recordFor('k1')!.originalEditionCovers, isTrue);

    // 不带选择重刮：沿用记下的选择。
    final BookArtSeriesPlan again = await scrape();
    expect(again.originalEditionCovers, isTrue);
    expect(store.hasCover('k2'), isTrue);

    final BookArtSeriesPlan keep = await scrape(<String, bool>{
      first.seriesKey: false,
    });
    expect(keep.originalEditionCovers, isFalse);
    expect(store.hasCover('k2'), isFalse, reason: '改回保留书里的封面：原版封面删掉');
    expect(store.recordFor('k2')?.originalEditionCovers ?? false, isFalse);
    expect(
      store.recordFor('k1')!.coverUrl,
      'https://images.mangabaka.dev/volume/zh1',
    );
  });

  // BUG-5287：选了「用 MangaBaka 封面」后本语言补上了这一卷、但不如书里的清晰：
  // 本语言那张不写，旧的日文版封面也不能接着盖在中文版上。
  test('原版封面在本语言补卷后不再保留：本语言不如书里清晰时露出书里的封面', () async {
    await seed('k1', 'テスト漫画 1');
    final Directory extract = await Directory(
      '${thumbs.path}/extract_k2',
    ).create();
    await File('${extract.path}/cover.png').writeAsBytes(png(1600, 2400));
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'k2',
        title: 'テスト漫画 2',
        epubPath: '/nonexistent/k2.cbz',
        extractDir: extract.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
        author: const Value<String?>('Taro'),
        format: const Value<String>('manga'),
        coverPath: const Value<String?>('cover.png'),
      ),
    );
    await db.updateEpubBookLanguage('k1', 'zh-Hant');
    await db.updateEpubBookLanguage('k2', 'zh-TW');
    Map<String, Object?> zh(int id, String index) => mbImage(id, index)
      ..['language'] = 'zh-tw'
      ..['image'] = <String, Object?>{
        'raw': <String, Object?>{
          'url': 'https://images.mangabaka.dev/volume/zh$index',
          'width': 1200,
          'height': 1800,
          'format': 'jpeg',
        },
      };
    bool zhVolume2 = false;
    Future<http.Response> handler(http.Request req) async {
      if (req.url.path == '/v1/series/100/images' &&
          req.url.queryParameters['type'] == 'volume') {
        return page(<Object?>[
          mbImage(1, '1'),
          mbImage(2, '2'),
          zh(11, '1'),
          if (zhVolume2) zh(12, '2'),
        ]);
      }
      return mangaBakaOk(req);
    }

    Future<BookArtSeriesPlan> scrape([
      Map<String, bool> choice = const <String, bool>{},
    ]) async {
      final BookArtScrapeService svc = service(handler);
      final BookArtRunResult result = await svc.run(
        <String>['k1', 'k2'],
        originalEditionCovers: choice,
        onlyPinnedGroups: choice.isNotEmpty,
      );
      svc.close();
      return result.series.single;
    }

    final BookArtSeriesPlan first = await scrape();
    await scrape(<String, bool>{first.seriesKey: true});
    expect(store.hasCover('k2'), isTrue, reason: '选了原版封面：不与书里的封面比清晰度');
    expect(store.recordFor('k2')!.coverFromOriginalEdition, isTrue);

    zhVolume2 = true;
    final BookArtSeriesPlan again = await scrape();
    expect(again.originalEditionCovers, isTrue);
    expect(
      again.books.singleWhere((BookArtBookPlan b) => b.bookKey == 'k2').outcome,
      BookArtBookOutcome.localSharper,
    );
    expect(store.hasCover('k2'), isFalse, reason: '日文版封面不再盖着中文版');
    expect(store.recordFor('k2')!.coverFromOriginalEdition, isFalse);
    expect(store.recordFor('k2')!.originalEditionCovers, isTrue);
  });

  test('dryRun 出同结构计划但不下载不写', () async {
    await seed('k1', 'テスト漫画 1');
    final BookArtScrapeService svc = service(mangaBakaOk);
    final BookArtRunResult result = await svc.run(<String>['k1'], dryRun: true);
    svc.close();
    expect(
      result.series.single.books.single.outcome,
      BookArtBookOutcome.written,
    );
    expect(result.toJson()['series'], isA<List<Object?>>());
    expect(store.hasCover('k1'), isFalse);
    expect(
      requests.where((Uri u) => u.host == 'images.mangabaka.dev'),
      isEmpty,
    );
  });

  test('MangaBaka 报错 → 回落 Bangumi 单行本封面', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    final BookArtScrapeService svc = service((http.Request req) async {
      if (req.url.host == 'api.mangabaka.org') {
        return http.Response('boom', 500);
      }
      return bangumi(req) ?? image(req) ?? http.Response('?', 404);
    });
    final BookArtRunResult result = await svc.run(<String>['k1', 'k2']);
    svc.close();
    final BookArtSeriesPlan plan = result.series.single;
    expect(plan.source, BookArtSource.bangumi);
    expect(plan.errors.single, startsWith('MangaBaka'));
    expect(result.count(BookArtBookOutcome.written), 2);
    expect(store.recordFor('k1')!.coverSource, 'bangumi');
    expect(result.usesMangaBaka, isFalse);
  });

  test('MangaBaka 429（Retry-After 超 60 秒）→ 停用并回落 Bangumi，不等待', () async {
    await seed('k1', 'テスト漫画 1');
    final List<Duration> waited = <Duration>[];
    final BookArtScrapeService svc = service((http.Request req) async {
      if (req.url.host == 'api.mangabaka.org') {
        return http.Response(
          'slow down',
          429,
          headers: const <String, String>{'retry-after': '120'},
        );
      }
      return bangumi(req) ?? image(req) ?? http.Response('?', 404);
    }, wait: (Duration d) async => waited.add(d));
    final BookArtRunResult result = await svc.run(<String>['k1']);
    svc.close();
    expect(waited, isEmpty);
    expect(result.mangaBakaRateLimited, isTrue);
    expect(result.series.single.source, BookArtSource.bangumi);
    expect(store.hasCover('k1'), isTrue);
  });

  test('下载到的不是图片：该卷记失败，不写盘', () async {
    await seed('k1', 'テスト漫画 1');
    final BookArtScrapeService svc = service((http.Request req) async {
      if (req.url.host == 'images.mangabaka.dev' &&
          req.url.path.startsWith('/volume')) {
        return http.Response(
          '<html>blocked</html>',
          200,
          headers: const <String, String>{'content-type': 'text/html'},
        );
      }
      return mangaBakaOk(req);
    });
    final BookArtRunResult result = await svc.run(<String>['k1']);
    svc.close();
    expect(result.count(BookArtBookOutcome.failed), 1);
    expect(store.hasCover('k1'), isFalse);
  });

  test('本地内嵌封面更清晰：保留本地，不写', () async {
    final Directory extract = await Directory(
      '${thumbs.path}/extract_k1',
    ).create();
    await File('${extract.path}/cover.png').writeAsBytes(png(1600, 2400));
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'k1',
        title: 'テスト漫画 1',
        epubPath: '/nonexistent/k1.cbz',
        extractDir: extract.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
        author: const Value<String?>('Taro'),
        format: const Value<String>('manga'),
        coverPath: const Value<String?>('cover.png'),
      ),
    );
    final BookArtScrapeService svc = service(mangaBakaOk);
    final BookArtRunResult result = await svc.run(<String>['k1']);
    svc.close();
    expect(
      result.series.single.books.single.outcome,
      BookArtBookOutcome.localSharper,
    );
    expect(store.hasCover('k1'), isFalse);
  });

  test('标题对不上：拒绝，不写', () async {
    await seed('k1', '全然違う本 1');
    final BookArtScrapeService svc = service((http.Request req) async {
      if (req.url.host == 'api.bgm.tv') {
        return json(<String, Object?>{'data': <Object?>[]});
      }
      return mangaBakaOk(req);
    });
    final BookArtRunResult result = await svc.run(<String>['k1']);
    svc.close();
    expect(result.series.single.decision, isNot(BookArtDecision.accepted));
    expect(store.hasCover('k1'), isFalse);
  });

  http.Response mbDown(http.Request req) => http.Response('boom', 500);

  test('重刮时 MangaBaka 出错回落 Bangumi：不拿小图换掉已有的原图，横幅保留', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    final BookArtScrapeService first = service(mangaBakaOk);
    await first.run(<String>['k1', 'k2']);
    first.close();
    final List<int> before = store.coverFileFor('k1')!.readAsBytesSync();

    final BookArtScrapeService second = service((http.Request req) async {
      if (req.url.host == 'api.mangabaka.org') return mbDown(req);
      return bangumi(req) ?? image(req) ?? http.Response('?', 404);
    });
    final BookArtRunResult result = await second.run(<String>['k1', 'k2']);
    second.close();

    expect(result.series.single.source, BookArtSource.bangumi);
    expect(result.count(BookArtBookOutcome.unchanged), 2);
    expect(result.count(BookArtBookOutcome.written), 0);
    expect(store.coverFileFor('k1')!.readAsBytesSync(), before);
    expect(store.recordFor('k1')!.coverSource, 'mangabaka');
    expect(store.backdropForCollection(<String>['k1', 'k2']), isNotNull);
  });

  test('重刮时横幅下载失败：同系列沿用旧横幅引用', () async {
    await seed('k1', 'テスト漫画 1');
    final BookArtScrapeService first = service(mangaBakaOk);
    await first.run(<String>['k1']);
    first.close();
    final String? bannerKey = store.recordFor('k1')!.bannerKey;
    expect(bannerKey, isNotNull);
    // 让卷封面看起来比已有的大：已有记录的尺寸改小。
    await store.write(
      record: BookArtRecord(
        bookKey: 'k1',
        source: 'mangabaka',
        seriesId: '100',
        seriesTitle: 'Test Manga',
        coverSource: 'mangabaka',
        coverUrl: 'https://images.mangabaka.dev/volume/1',
        coverWidth: 1,
        coverHeight: 1,
        bannerKey: bannerKey,
        scrapedAt: 1,
      ),
    );

    final BookArtScrapeService second = service((http.Request req) async {
      if (req.url.host == 'images.mangabaka.dev' &&
          req.url.path.startsWith('/banner')) {
        return http.Response('cdn hiccup', 503);
      }
      return mangaBakaOk(req);
    });
    final BookArtRunResult result = await second.run(<String>['k1']);
    second.close();

    expect(result.count(BookArtBookOutcome.written), 1);
    expect(result.series.single.errors.single, startsWith('banner'));
    expect(store.recordFor('k1')!.bannerKey, bannerKey);
    expect(store.backdropForBook('k1'), isNotNull);
  });

  test('横幅文件头完整但解码不了：只丢横幅，卷封面照写，不中断', () async {
    await seed('k1', 'テスト漫画 1');
    final List<int> truncated = png(48, 16).sublist(0, 40);
    final BookArtScrapeService svc = service((http.Request req) async {
      if (req.url.host == 'images.mangabaka.dev' &&
          req.url.path.startsWith('/banner')) {
        return http.Response.bytes(
          truncated,
          200,
          headers: const <String, String>{'content-type': 'image/png'},
        );
      }
      return mangaBakaOk(req);
    });
    final BookArtRunResult result = await svc.run(<String>['k1']);
    svc.close();
    expect(result.count(BookArtBookOutcome.written), 1);
    expect(result.series.single.banner, isNull);
    expect(result.series.single.errors.single, startsWith('banner'));
    expect(store.backdropForBook('k1'), isNull);
  });

  test('Bangumi 补卷要求种类一致：轻小说不补漫画版单行本封面', () async {
    for (final int v in <int>[1, 2]) {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'n$v',
          title: 'テスト漫画 $v',
          epubPath: '/nonexistent/n$v.epub',
          extractDir: '/nonexistent/n$v',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1000,
          author: const Value<String?>('Taro'),
          format: const Value<String>('epub'),
        ),
      );
    }
    final List<int> bigBangumi = png(1000, 1500, shade: 90);
    final BookArtScrapeService svc = service((http.Request req) async {
      if (req.url.host == 'lain.bgm.tv') {
        return http.Response.bytes(
          bigBangumi,
          200,
          headers: const <String, String>{'content-type': 'image/png'},
        );
      }
      final http.Response? bgm = bangumi(req);
      if (bgm != null) return bgm;
      final String path = req.url.path;
      if (path == '/v1/series/search') {
        return page(<Object?>[mbSeries(type: 'light_novel', finalVolume: '2')]);
      }
      if (path == '/v1/series/100/images') {
        if (req.url.queryParameters['type'] == 'banner') {
          return page(<Object?>[]);
        }
        // 短边 < 1000：会去量 Bangumi 那张。
        return page(<Object?>[
          mbImage(1, '1', width: 600, height: 900),
          mbImage(2, '2', width: 600, height: 900),
        ]);
      }
      return image(req) ?? http.Response('unexpected ${req.url}', 500);
    });
    final BookArtRunResult result = await svc.run(<String>['n1', 'n2']);
    svc.close();
    expect(result.series.single.source, BookArtSource.mangabaka);
    expect(result.count(BookArtBookOutcome.written), 2);
    expect(store.recordFor('n1')!.coverSource, 'mangabaka');
    expect(store.recordFor('n2')!.coverSource, 'mangabaka');
  });

  test('MangaBaka 待确认时整组待确认：Bangumi 能自动采用也不接管', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    final BookArtScrapeService svc = service((http.Request req) async {
      final http.Response? bgm = bangumi(req);
      if (bgm != null) return bgm;
      final String path = req.url.path;
      if (path == '/v1/series/search') {
        return page(<Object?>[mbSeries(), mbSeries(id: 101)]);
      }
      if (path == '/v1/series/100/images' || path == '/v1/series/101/images') {
        return page(<Object?>[mbImage(1, '1'), mbImage(2, '2')]);
      }
      return image(req) ?? http.Response('unexpected ${req.url}', 500);
    });
    final BookArtRunResult result = await svc.run(<String>['k1', 'k2']);
    svc.close();
    final BookArtSeriesPlan plan = result.series.single;
    expect(plan.decision, BookArtDecision.needsConfirm);
    expect(
      plan.options.where(
        (BookArtSeriesOption o) => o.source == BookArtSource.mangabaka,
      ),
      hasLength(2),
    );
    expect(store.hasCover('k1'), isFalse);
  });

  test('钉死的系列记进刮削层：之后不给 pin 也沿用，不再搜 MangaBaka', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    final String seriesKey = parseBookSeriesKey('テスト漫画 1')!.key;
    final BookArtScrapeService first = service((http.Request req) async {
      return bangumi(req) ?? image(req) ?? http.Response('?', 404);
    });
    await first.run(
      <String>['k1', 'k2'],
      pins: <String, BookArtSeriesPin>{
        seriesKey: const BookArtSeriesPin(
          source: BookArtSource.bangumi,
          id: '7',
        ),
      },
    );
    first.close();
    expect(store.recordFor('k1')!.pinned, isTrue);
    requests.clear();

    final BookArtScrapeService second = service(
      (http.Request req) async => bangumi(req) ?? await mangaBakaOk(req),
    );
    final BookArtRunResult result = await second.run(<String>['k1', 'k2']);
    second.close();
    expect(result.series.single.source, BookArtSource.bangumi);
    expect(result.series.single.seriesId, '7');
    expect(requests.where((Uri u) => u.host == 'api.mangabaka.org'), isEmpty);
  });

  test('钉死 MangaBaka 系列：它缺的卷照样由 Bangumi 单行本补（与追踪固定链接同口径）', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    final BookArtScrapeService svc = service((http.Request req) async {
      final http.Response? bgm = bangumi(req);
      if (bgm != null) return bgm;
      final String path = req.url.path;
      if (path == '/v1/series/100') {
        return json(<String, Object?>{'status': 200, 'data': mbSeries()});
      }
      if (path == '/v1/series/100/images' &&
          req.url.queryParameters['type'] != 'banner') {
        // MangaBaka 只有第 1 卷的日文封面。
        return page(<Object?>[mbImage(1, '1')]);
      }
      return mangaBakaOk(req);
    });
    final BookArtRunResult result = await svc.run(
      <String>['k1', 'k2'],
      pins: <String, BookArtSeriesPin>{
        parseBookSeriesKey('テスト漫画 1')!.key: const BookArtSeriesPin(
          source: BookArtSource.mangabaka,
          id: '100',
        ),
      },
    );
    svc.close();
    final BookArtSeriesPlan plan = result.series.single;
    expect(plan.source, BookArtSource.mangabaka);
    expect(plan.seriesId, '100');
    expect(result.count(BookArtBookOutcome.written), 2);
    expect(store.recordFor('k1')!.coverSource, 'mangabaka');
    expect(store.recordFor('k2')!.coverSource, 'bangumi');
    // 记录仍是用户钉的那个 MangaBaka 系列。
    expect(store.recordFor('k2')!.source, 'mangabaka');
    expect(store.recordFor('k2')!.pinned, isTrue);
  });

  test('单本移除的贴错封面记为否决：重刮不再写回同一张', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    final BookArtScrapeService first = service(mangaBakaOk);
    await first.run(<String>['k1', 'k2']);
    first.close();
    const String wrong = 'https://images.mangabaka.dev/volume/1';
    expect(store.recordFor('k1')!.coverUrl, wrong);
    await store.rejectCover('k1');
    expect(store.hasCover('k1'), isFalse);

    final BookArtScrapeService second = service(
      (http.Request req) async => bangumi(req) ?? await mangaBakaOk(req),
    );
    await second.run(<String>['k1', 'k2']);
    second.close();
    final BookArtRecord record = store.recordFor('k1')!;
    expect(record.coverUrl, isNot(wrong));
    expect(record.coverSource, 'bangumi');
    expect(record.rejectedCoverUrls, contains(wrong));
  });

  test('改钉另一个系列且它没有这一卷：旧系列的封面删掉，记录换成新系列', () async {
    await seed('k1', 'テスト漫画 1');
    final BookArtScrapeService first = service(mangaBakaOk);
    await first.run(<String>['k1']);
    first.close();
    expect(store.hasCover('k1'), isTrue);

    final BookArtScrapeService second = service((http.Request req) async {
      final String path = req.url.path;
      if (path == '/v1/series/200') {
        return json(<String, Object?>{
          'status': 200,
          'data': mbSeries(id: 200),
        });
      }
      if (path == '/v1/series/200/images') return page(<Object?>[]);
      return mangaBakaOk(req);
    });
    final BookArtRunResult result = await second.run(
      <String>['k1'],
      pins: <String, BookArtSeriesPin>{
        parseBookSeriesKey('テスト漫画 1')!.key: const BookArtSeriesPin(
          source: BookArtSource.mangabaka,
          id: '200',
        ),
      },
    );
    second.close();
    expect(
      result.series.single.books.single.outcome,
      BookArtBookOutcome.noCandidate,
    );
    expect(store.hasCover('k1'), isFalse);
    expect(store.recordFor('k1')!.seriesId, '200');
    expect(store.recordFor('k1')!.coverUrl, isNull);
    expect(store.backdropForBook('k1'), isNull);
  });

  test('本地有封面但量不出尺寸：按本地更清晰处理，不覆盖', () async {
    final Directory extract = await Directory(
      '${thumbs.path}/extract_bad',
    ).create();
    await File(
      '${extract.path}/cover.png',
    ).writeAsBytes(List<int>.filled(4096, 0x41));
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'k1',
        title: 'テスト漫画 1',
        epubPath: '/nonexistent/k1.cbz',
        extractDir: extract.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
        author: const Value<String?>('Taro'),
        format: const Value<String>('manga'),
        coverPath: const Value<String?>('cover.png'),
      ),
    );
    final BookArtScrapeService svc = service(mangaBakaOk);
    final BookArtRunResult result = await svc.run(<String>['k1']);
    svc.close();
    expect(
      result.series.single.books.single.outcome,
      BookArtBookOutcome.localSharper,
    );
    expect(store.hasCover('k1'), isFalse);
  });

  test('界面路径 recordUndo: false 不留撤销快照', () async {
    await seed('k1', 'テスト漫画 1');
    final BookArtScrapeService svc = service(mangaBakaOk);
    final BookArtRunResult result = await svc.run(<String>[
      'k1',
    ], recordUndo: false);
    svc.close();
    expect(result.count(BookArtBookOutcome.written), 1);
    expect(result.snapshots, isEmpty);
  });

  test('Bangumi 补卷不收严格同名系列之外的同名衍生作（前缀 + 副标题）', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    final List<int> bigBangumi = png(1000, 1500, shade: 90);
    const Map<String, Object?> spinOff = <String, Object?>{
      'id': 8,
      'name': 'テスト漫画 星の章',
      'name_cn': '',
      'platform': '漫画',
      'series': true,
      'nsfw': false,
      'volumes': 2,
      'infobox': <Object?>[
        <String, Object?>{'key': '作者', 'value': 'Taro'},
      ],
      'images': <String, Object?>{'large': 'https://lain.bgm.tv/s/8.jpg'},
    };
    final BookArtScrapeService svc = service((http.Request req) async {
      final String path = req.url.path;
      if (req.url.host == 'lain.bgm.tv') {
        return http.Response.bytes(
          bigBangumi,
          200,
          headers: const <String, String>{'content-type': 'image/png'},
        );
      }
      if (req.url.host == 'api.bgm.tv') {
        if (path == '/v0/search/subjects') {
          return json(<String, Object?>{
            'data': <Object?>[bangumiSeries7, spinOff],
          });
        }
        // 严格同名的主系列没有单行本封面（覆盖率 0 被丢）。
        if (path == '/v0/subjects/7/subjects') return json(<Object?>[]);
        if (path == '/v0/subjects/8/subjects') {
          return json(<Object?>[
            for (final int v in <int>[1, 2])
              <String, Object?>{
                'id': 80 + v,
                'name': 'テスト漫画 星の章 ($v)',
                'name_cn': '',
                'relation': '单行本',
                'type': 1,
                'images': <String, Object?>{
                  'large': 'https://lain.bgm.tv/pic/cover/l/8_$v.jpg',
                },
              },
          ]);
        }
        return http.Response('unexpected ${req.url}', 404);
      }
      if (path == '/v1/series/search') return page(<Object?>[mbSeries()]);
      if (path == '/v1/series/100/images') {
        if (req.url.queryParameters['type'] == 'banner') {
          return page(<Object?>[]);
        }
        // 短边 < 1000：会去问 Bangumi 补更清晰的。
        return page(<Object?>[
          mbImage(1, '1', width: 600, height: 900),
          mbImage(2, '2', width: 600, height: 900),
        ]);
      }
      return image(req) ?? http.Response('unexpected ${req.url}', 500);
    });
    final BookArtRunResult result = await svc.run(<String>['k1', 'k2']);
    svc.close();
    // Bangumi 确实被问过、衍生作的单行本也拉过——不是因为没去问才没用它。
    expect(
      requests.where((Uri u) => u.path == '/v0/subjects/8/subjects'),
      isNotEmpty,
    );
    expect(result.series.single.source, BookArtSource.mangabaka);
    expect(result.count(BookArtBookOutcome.written), 2);
    expect(store.recordFor('k1')!.coverSource, 'mangabaka');
    expect(store.recordFor('k2')!.coverSource, 'mangabaka');
  });

  test('全名搜到的都不像：再用去掉副标题的查询搜一次；全名已有像样的就不再搜', () async {
    // 结尾成对的 ～副标题～ 已由系列键剥掉（BUG-4791），这里用系列键保留、查询再切的冒号副标题。
    const String title = 'テスト漫画：ブルー 1';
    final String full = parseBookSeriesKey(title)!.seriesTitle;
    expect(full, contains('ブルー'));
    await seed('k1', title);

    Future<List<String>> queriesFor(Map<String, Object?> fullHit) async {
      final List<String> queries = <String>[];
      final BookArtScrapeService svc = service((http.Request req) async {
        if (req.url.path == '/v1/series/search') {
          final String q = req.url.queryParameters['q'] ?? '';
          queries.add(q);
          return page(<Object?>[if (q == full) fullHit else mbSeries()]);
        }
        return bangumi(req) ?? await mangaBakaOk(req);
      });
      await svc.run(<String>['k1'], dryRun: true);
      svc.close();
      return queries;
    }

    final List<String> retried = await queriesFor(<String, Object?>{
      ...mbSeries(id: 300),
      'title': 'Other',
      'native_title': '全然違う作品',
      'romanized_title': 'Zenzen Chigau',
    });
    expect(retried, <String>[full, 'テスト漫画']);

    final List<String> once = await queriesFor(<String, Object?>{
      ...mbSeries(),
      'native_title': full,
    });
    expect(once, <String>[full]);
  });

  test('双语书名的查询序列：全名 → 日文段 → 罗马字段；单语书名不多出查询', () {
    expect(BookArtScrapeService.queriesFor('Horimiya ホリミヤ'), <String>[
      'Horimiya ホリミヤ',
      'ホリミヤ',
      'Horimiya',
    ]);
    expect(BookArtScrapeService.queriesFor('テスト漫画：ブルー'), <String>[
      'テスト漫画：ブルー',
      'テスト漫画',
    ]);
    // 拉丁书名词间本来就有空格，不再切出「One」这种必然搜偏的词。
    expect(BookArtScrapeService.queriesFor('One Piece'), <String>['One Piece']);
  });

  // review-book-scrape-query-unify：批量与手动搜索弹窗同一份 bookSearchQueries。
  test('查询序列与手动搜索统一：剥打头标签、拆混写名、最后试主标题', () {
    expect(BookArtScrapeService.queriesFor('[川原礫] ソードアート・オンライン'), <String>[
      'ソードアート・オンライン',
    ]);
    expect(BookArtScrapeService.queriesFor('ソードアート・オンライン プログレッシブ'), <String>[
      'ソードアート・オンライン プログレッシブ',
      'ソードアート・オンライン',
    ]);
    expect(BookArtScrapeService.queriesFor('Re:ゼロから始める異世界生活'), <String>[
      'Re:ゼロから始める異世界生活',
    ]);
  });

  test('书名带打头作者标签：搜索与判档都用去掉标签的系列名，照常采用', () async {
    await seed('k1', '[Taro] テスト漫画 1');
    await seed('k2', '[Taro] テスト漫画 2');
    final List<String> queries = <String>[];
    final BookArtScrapeService svc = service((http.Request req) async {
      if (req.url.path == '/v1/series/search') {
        queries.add(req.url.queryParameters['q'] ?? '');
      }
      return mangaBakaOk(req);
    });
    final BookArtRunResult result = await svc.run(<String>['k1', 'k2']);
    svc.close();

    expect(queries, <String>['テスト漫画']);
    expect(result.series.single.decision, BookArtDecision.accepted);
    expect(result.count(BookArtBookOutcome.written), 2);
  });

  // 系列名本身以数字结尾（`Steins;Gate 0`）：组名已去过一次卷号，搜索 / 判档用的
  // 系列名不能拿组名再解析一次，否则 `0` 又被当成卷号去掉、搜成别的系列。
  test('系列名以数字结尾：只去一次卷号，搜的仍是完整系列名', () async {
    await seed('k1', 'Steins;Gate 0 1');
    await seed('k2', 'Steins;Gate 0 2');
    final List<String> queries = <String>[];
    final BookArtScrapeService svc = service((http.Request req) async {
      if (req.url.path == '/v1/series/search') {
        queries.add(req.url.queryParameters['q'] ?? '');
      }
      return mangaBakaOk(req);
    });
    await svc.run(<String>['k1', 'k2']);
    svc.close();

    expect(queries, <String>['Steins;Gate 0']);
    expect(BookArtScrapeService.queriesFor('Steins;Gate 0 1'), <String>[
      'Steins;Gate 0',
    ]);
  });

  // Bangumi 是关键词精确搜索：「Horimiya ホリミヤ」零结果，只有「ホリミヤ」搜得到。
  // 曾只用全名搜一次，双语书名的系列从来拿不到 Bangumi 候选。
  test('Bangumi 全名零结果：改用日文段再搜，拿到候选', () async {
    await seed('k1', 'Test テスト漫画 1');
    await seed('k2', 'Test テスト漫画 2');
    final List<String> keywords = <String>[];
    final BookArtScrapeService svc = service((http.Request req) async {
      if (req.url.host == 'api.mangabaka.org') {
        return http.Response('boom', 500);
      }
      if (req.url.path == '/v0/search/subjects') {
        final String keyword =
            (jsonDecode(req.body) as Map<String, Object?>)['keyword']!
                as String;
        keywords.add(keyword);
        return json(<String, Object?>{
          'data': <Object?>[if (keyword == 'テスト漫画') bangumiSeries7],
        });
      }
      return bangumi(req) ?? image(req) ?? http.Response('?', 404);
    });
    final BookArtRunResult result = await svc.run(<String>['k1', 'k2']);
    svc.close();

    expect(keywords, <String>['Test テスト漫画', 'テスト漫画']);
    final BookArtSeriesPlan plan = result.series.single;
    expect(
      plan.source == BookArtSource.bangumi ||
          plan.options.any(
            (BookArtSeriesOption o) =>
                o.source == BookArtSource.bangumi && o.id == '7',
          ),
      isTrue,
      reason: 'Bangumi 系列 7 应被采用或列为候选：${plan.decision} ${plan.reason}',
    );
  });

  test('刮削进行中书被删了：这本不再写入，不留孤儿文件', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    final BookArtScrapeService svc = service((http.Request req) async {
      if (req.url.path == '/volume/2') await db.deleteEpubBook('k2');
      return mangaBakaOk(req);
    });
    final BookArtRunResult result = await svc.run(<String>['k1', 'k2']);
    svc.close();
    final BookArtBookPlan k2 = result.series.single.books.firstWhere(
      (BookArtBookPlan b) => b.bookKey == 'k2',
    );
    expect(k2.outcome, BookArtBookOutcome.failed);
    expect(k2.error, 'book was removed');
    expect(store.hasCover('k1'), isTrue);
    expect(store.hasCover('k2'), isFalse);
    expect(store.recordFor('k2'), isNull);
    expect(File(store.coverPathFor('k2')).existsSync(), isFalse);
  });

  // ── AniList 横幅回落 ──

  /// AniList media（GraphQL 形状，字段同 anilist_books 的 `_mediaFields`）。
  Map<String, Object?> aniListMedia({
    int id = 555,
    String native = 'テスト漫画',
    String format = 'MANGA',
    bool adult = false,
    String? banner =
        'https://s4.anilist.co/file/anilistcdn/media/manga/banner/555.jpg',
    String author = 'Taro',
  }) => <String, Object?>{
    'id': id,
    'siteUrl': 'https://anilist.co/manga/$id',
    'isAdult': adult,
    'bannerImage': banner,
    'format': format,
    'countryOfOrigin': 'JP',
    'title': <String, Object?>{
      'romaji': 'Tesuto Manga',
      'english': null,
      'native': native,
    },
    'coverImage': <String, Object?>{
      'extraLarge': 'https://s4.anilist.co/file/cover/$id.jpg',
    },
    'startDate': <String, Object?>{'year': 2020},
    'description': '',
    'staff': <String, Object?>{
      'edges': <Object?>[
        <String, Object?>{
          'role': 'Story & Art',
          'node': <String, Object?>{
            'name': <String, Object?>{'full': author, 'native': author},
          },
        },
      ],
    },
  };

  http.Response aniListSearch(List<Map<String, Object?>> media) =>
      json(<String, Object?>{
        'data': <String, Object?>{
          'Page': <String, Object?>{'media': media},
        },
      });

  http.Response aniListById(Map<String, Object?> media) =>
      json(<String, Object?>{
        'data': <String, Object?>{'Media': media},
      });

  bool isSearch(Map<String, Object?> body) =>
      '${body['query']}'.contains('Page(');

  /// MangaBaka 系列 100 带 AniList id 555，但没有横幅。
  Future<http.Response> mangaBakaNoBanner(http.Request req) async {
    final http.Response? img = image(req);
    if (img != null) return img;
    final String path = req.url.path;
    if (path == '/v1/series/search') {
      return page(<Object?>[
        <String, Object?>{
          ...mbSeries(),
          'source': <String, Object?>{
            'anilist': <String, Object?>{'id': 555, 'rating': 8.2},
          },
        },
      ]);
    }
    if (path == '/v1/series/100/images') {
      if (req.url.queryParameters['type'] == 'banner') {
        return page(<Object?>[]);
      }
      return page(<Object?>[mbImage(1, '1'), mbImage(2, '2'), mbImage(3, '3')]);
    }
    return http.Response('unexpected ${req.url}', 500);
  }

  Future<http.Response> bangumiOnly(http.Request req) async {
    if (req.url.host == 'api.mangabaka.org') {
      return http.Response('boom', 500);
    }
    return bangumi(req) ?? image(req) ?? http.Response('?', 404);
  }

  test('MangaBaka 没有横幅：按它记的 AniList id 直取横幅，不按标题搜', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    final BookArtScrapeService svc = service(
      mangaBakaNoBanner,
      aniList: (Map<String, Object?> body) {
        expect(isSearch(body), isFalse, reason: '有 AniList id 时不搜标题');
        expect((body['variables']! as Map<String, Object?>)['id'], 555);
        return aniListById(aniListMedia());
      },
    );
    final BookArtRunResult result = await svc.run(<String>['k1', 'k2']);
    svc.close();

    final BookArtSeriesPlan plan = result.series.single;
    expect(plan.source, BookArtSource.mangabaka);
    expect(plan.errors, isEmpty);
    expect(plan.banner?.source, BookArtSource.anilist);
    expect(aniListQueries, hasLength(1));
    final BookArtRecord record = store.recordFor('k1')!;
    expect(record.bannerKey, 'anilist_555');
    expect(record.bannerUrl, contains('s4.anilist.co'));
    // AniList 不给尺寸：下载后量出来记进记录。
    expect(record.bannerWidth, 57);
    expect(record.bannerHeight, 12);
    expect(store.recordFor('k2')!.bannerKey, 'anilist_555');
    expect(store.backdropForCollection(<String>['k1', 'k2']), isNotNull);
    // 卷封面仍来自 MangaBaka：署名照旧。
    expect(result.usesMangaBaka, isTrue);
  });

  test('MangaBaka 有横幅：不去问 AniList', () async {
    await seed('k1', 'テスト漫画 1');
    final BookArtScrapeService svc = service(mangaBakaOk);
    final BookArtRunResult result = await svc.run(<String>['k1']);
    svc.close();
    expect(result.series.single.banner?.source, BookArtSource.mangabaka);
    expect(aniListQueries, isEmpty);
    expect(store.recordFor('k1')!.bannerKey, 'mangabaka_100');
  });

  test('只在 Bangumi 上认定：AniList 唯一的严格同名同种类条目出横幅', () async {
    await seed('k1', 'テスト漫画 1');
    await seed('k2', 'テスト漫画 2');
    final BookArtScrapeService svc = service(
      bangumiOnly,
      aniList: (Map<String, Object?> body) {
        expect(isSearch(body), isTrue);
        expect((body['variables']! as Map<String, Object?>)['search'], 'テスト漫画');
        return aniListSearch(<Map<String, Object?>>[
          // 同名轻小说（种类不同）与同名衍生作（副标题）都不算。
          aniListMedia(id: 1, format: 'NOVEL'),
          aniListMedia(id: 2, native: 'テスト漫画 外伝'),
          aniListMedia(id: 555),
        ]);
      },
    );
    final BookArtRunResult result = await svc.run(<String>['k1', 'k2']);
    svc.close();
    final BookArtSeriesPlan plan = result.series.single;
    expect(plan.source, BookArtSource.bangumi);
    expect(plan.banner?.source, BookArtSource.anilist);
    expect(store.recordFor('k1')!.bannerKey, 'anilist_555');
    expect(store.recordFor('k1')!.coverSource, 'bangumi');
    expect(result.usesMangaBaka, isFalse);
  });

  test('AniList 同名同种类有两条（重名作品）：不取横幅，也不报错', () async {
    await seed('k1', 'テスト漫画 1');
    final BookArtScrapeService svc = service(
      bangumiOnly,
      aniList: (Map<String, Object?> body) => aniListSearch(
        <Map<String, Object?>>[aniListMedia(id: 555), aniListMedia(id: 556)],
      ),
    );
    final BookArtRunResult result = await svc.run(<String>['k1']);
    svc.close();
    final BookArtSeriesPlan plan = result.series.single;
    expect(plan.banner, isNull);
    expect(plan.errors.where((String e) => e.startsWith('AniList')), isEmpty);
    expect(store.recordFor('k1')!.bannerKey, isNull);
    expect(store.hasCover('k1'), isTrue);
  });

  test('AniList 条目成人向 / 作者不同：不取横幅', () async {
    await seed('k1', 'テスト漫画 1');
    for (final Map<String, Object?> media in <Map<String, Object?>>[
      aniListMedia(adult: true),
      aniListMedia(author: 'Hanako'),
    ]) {
      final BookArtScrapeService svc = service(
        bangumiOnly,
        aniList: (Map<String, Object?> body) =>
            aniListSearch(<Map<String, Object?>>[media]),
      );
      final BookArtRunResult result = await svc.run(<String>['k1']);
      svc.close();
      expect(result.series.single.banner, isNull);
      expect(store.recordFor('k1')!.bannerKey, isNull);
    }
  });

  test('AniList 出错：记进摘要，卷封面照写', () async {
    await seed('k1', 'テスト漫画 1');
    final BookArtScrapeService svc = service(
      mangaBakaNoBanner,
      aniList: (Map<String, Object?> body) =>
          http.Response('upstream down', 503),
    );
    final BookArtRunResult result = await svc.run(<String>['k1']);
    svc.close();
    final BookArtSeriesPlan plan = result.series.single;
    expect(plan.banner, isNull);
    expect(plan.errors.single, startsWith('AniList banner'));
    expect(store.hasCover('k1'), isTrue);
    expect(store.recordFor('k1')!.bannerKey, isNull);
  });

  test('AniList 那张其实不是横幅（宽高比不够）：只丢横幅，卷封面照写', () async {
    await seed('k1', 'テスト漫画 1');
    final BookArtScrapeService svc = service((http.Request req) async {
      if (req.url.host == 's4.anilist.co') {
        return http.Response.bytes(
          png(20, 20),
          200,
          headers: const <String, String>{'content-type': 'image/png'},
        );
      }
      return mangaBakaNoBanner(req);
    }, aniList: (Map<String, Object?> body) => aniListById(aniListMedia()));
    final BookArtRunResult result = await svc.run(<String>['k1']);
    svc.close();
    expect(result.series.single.banner, isNull);
    expect(result.series.single.errors.single, startsWith('banner'));
    expect(store.recordFor('k1')!.bannerKey, isNull);
    expect(store.hasCover('k1'), isTrue);
  });
}
