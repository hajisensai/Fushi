import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/metadata/book_art_scrape_service.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart'
    show kBookScraperUserAgent;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart';
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

  setUp(() async {
    BookArtStore.resetForTesting();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    thumbs = await Directory.systemTemp.createTemp('fushi_book_art_svc_');
    store = BookArtStore.of(thumbs);
    requests = <Uri>[];
    userAgents = <String>[];
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

  BookArtScrapeService service(
    Future<http.Response> Function(http.Request req) handler, {
    Future<void> Function(Duration)? wait,
  }) {
    final MockClient client = MockClient((http.Request req) async {
      requests.add(req.url);
      userAgents.add(req.headers['User-Agent'] ?? '');
      return handler(req);
    });
    return BookArtScrapeService(
      database: db,
      store: store,
      client: client,
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
    const String title = 'テスト漫画 ～ブルー～ 1';
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
}
