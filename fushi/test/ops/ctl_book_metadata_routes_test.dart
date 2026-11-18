import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/metadata/books/rakuten_books.dart';

import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_book_metadata_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_descriptions_book_metadata.dart'
    show kBookScrapeSourceNames;

import 'book_metadata_test_fixture.dart';

Matcher _ctlFailure(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory thumbs;
  late BookMetaTestModel model;
  late BookMetaRef ref;
  late List<CtlRoute> routes;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    thumbs = await Directory.systemTemp.createTemp('fushi_book_meta_');
    model = BookMetaTestModel(db, prefs, thumbs);
    ref = BookMetaRef(model);
    MediaSource.setDatabase(db);
    bookMetadataFacadeFactory = ({RakutenBooksCredentials? rakuten}) =>
        BookMetadataScrapeFacade(
          scraper: offlineScraper(
            subjects: <String, Map<String, Object?>>{
              '11': bangumiSubject('11', 'Yotsuba to!', cn: '四叶妹妹'),
            },
            searchHits: <Map<String, Object?>>[
              bangumiSubject('11', 'Yotsuba to!', cn: '四叶妹妹'),
            ],
          ),
          downloadImage: fakeDownloader(thumbs),
        );
    routes = buildBookMetadataCtlRoutes(OpContext(ref: ref));
  });

  tearDown(() async {
    bookMetadataFacadeFactory = BookMetadataScrapeFacade.new;
    await db.close();
    if (thumbs.existsSync()) await thumbs.delete(recursive: true);
  });

  CtlRoute route(String method, String pattern) => routes.singleWhere(
    (CtlRoute r) => r.method == method && r.pattern == pattern,
  );

  Future<Object?> call(
    String method,
    String pattern, {
    Map<String, String> params = const <String, String>{},
    Map<String, String> query = const <String, String>{},
    Map<String, Object?> body = const <String, Object?>{},
  }) => route(method, pattern).handler(
    CtlCall(
      method: method,
      path: pattern,
      params: params,
      query: query,
      body: body,
    ),
  );

  test('路由齐全（元数据刮削 + 每卷封面 / 横幅）', () {
    expect(
      <String>[for (final CtlRoute r in routes) '${r.method} ${r.pattern}'],
      <String>[
        'GET /api/admin/book/scrape',
        'GET /api/admin/book/scrape/:source/:id',
        'GET /api/admin/book/scrape/:source/:id/volumes',
        'POST /api/admin/book/items/:key/scrape',
        'POST /api/admin/book/collections/:id/scrape-art',
        'DELETE /api/admin/book/collections/:id/scrape-art',
        'DELETE /api/admin/book/items/:key/scraped-art',
      ],
    );
  });

  test('search：候选的线上形状；缺 query 400、未知源 400', () async {
    final Object? got = await call(
      'GET',
      kBookMetadataCtlSearch,
      query: <String, String>{'query': '四叶'},
    );
    final Map<String, Object?> first =
        ((got! as Map<String, Object?>)['candidates']! as List<Object?>).first!
            as Map<String, Object?>;
    expect(first['id'], '11');
    expect(first['title'], '四叶妹妹');
    expect(first['originalTitle'], 'Yotsuba to!');
    expect(first['source'], 'bangumi');
    expect(first['year'], 2010);
    expect(() => call('GET', kBookMetadataCtlSearch), _ctlFailure(400));
    expect(
      () => call(
        'GET',
        kBookMetadataCtlSearch,
        query: <String, String>{'query': 'x', 'source': 'amazon'},
      ),
      _ctlFailure(400),
    );
  });

  test('get：命中回候选，查无 404', () async {
    final Object? hit = await call(
      'GET',
      '$kBookMetadataCtlSearch/:source/:id',
      params: <String, String>{'source': 'bangumi', 'id': '11'},
    );
    expect((hit! as Map<String, Object?>)['title'], '四叶妹妹');
    expect(
      () => call(
        'GET',
        '$kBookMetadataCtlSearch/:source/:id',
        params: <String, String>{'source': 'bangumi', 'id': '999'},
      ),
      _ctlFailure(404),
    );
  });

  test('「在线服务」模块关掉：三条都 422', () async {
    model.disabled.add(ModuleId.services);
    expect(
      () => call(
        'GET',
        kBookMetadataCtlSearch,
        query: <String, String>{'query': 'x'},
      ),
      _ctlFailure(422),
    );
    expect(
      () => call(
        'POST',
        '$kBookMetadataCtlItems/:key/scrape',
        params: <String, String>{'key': 'book:x'},
        body: <String, Object?>{'id': '11'},
      ),
      _ctlFailure(422),
    );
  });

  test('apply：默认换封面 + 写条目资料；--title 写显示名；结果带快照与封面备份', () async {
    await seedBook(db, '猫');
    final Map<String, Object?> cover =
        (await call(
              'POST',
              '$kBookMetadataCtlItems/:key/scrape',
              params: <String, String>{'key': 'book:猫'},
              body: <String, Object?>{'id': '11'},
            ))!
            as Map<String, Object?>;
    expect(cover['applied'], <String>['cover', 'details']);
    expect(((cover['after']! as Map<String, Object?>)['coverSha']), isNotNull);
    // v155：默认连条目资料一起写（书架系列色块读它），键 = (epub, uid)。
    final String uid = (await db.resolveEpubBookUid('猫'))!;
    final ItemScrapeMetaRow meta = (await db.getItemScrapeMeta(
      MediaKind.epub,
      uid,
    ))!;
    expect(meta.source, 'bangumi');
    expect(meta.subjectId, '11');
    expect(meta.airDate, '2010-01-01');
    expect(meta.detailUrl, 'https://bgm.tv/subject/11');
    expect(
      (cover['before']! as Map<String, Object?>)['state'],
      containsPair('details', null),
      reason: '撤销快照记下「执行前没有资料」',
    );
    expect(ref.invalidations, greaterThan(0));

    final Map<String, Object?> both =
        (await call(
              'POST',
              '$kBookMetadataCtlItems/:key/scrape',
              params: <String, String>{'key': 'book:猫'},
              body: <String, Object?>{
                'id': '11',
                'fields': <String>['cover', 'title'],
              },
            ))!
            as Map<String, Object?>;
    expect(both['applied'], containsAll(<String>['cover', 'title']));
    final Map<String, Object?> before = both['before']! as Map<String, Object?>;
    // 第二次换封面时已有 override 封面：先留了备份。
    expect(File(before['coverBackupPath']! as String).existsSync(), isTrue);
    final ReaderFushiSource source = ReaderFushiSource.instance;
    expect(
      source.getOverrideTitleFromMediaItem(
        (await source.mediaItemForBookKey('猫'))!,
      ),
      '四叶妹妹',
    );
  });

  test('apply onlyEmpty：已有 override 封面 / 显示名的字段不覆盖，全被滤掉 → 422', () async {
    await seedBook(db, '鱼');
    Future<Object?> apply(List<String> fields) => call(
      'POST',
      '$kBookMetadataCtlItems/:key/scrape',
      params: <String, String>{'key': 'book:鱼'},
      body: <String, Object?>{'id': '11', 'fields': fields, 'onlyEmpty': true},
    );
    // 起初都空：照写。
    final Map<String, Object?> first =
        (await apply(<String>['cover']))! as Map<String, Object?>;
    expect(first['applied'], <String>['cover']);
    // 已有 override 封面：封面被滤掉，只写显示名。
    final Map<String, Object?> second =
        (await apply(<String>['cover', 'title']))! as Map<String, Object?>;
    expect(second['applied'], <String>['title']);
    expect(second['requested'], <String>['title']);
    // 两项都有值了：没东西写。
    expect(() => apply(<String>['cover', 'title']), _ctlFailure(422));
  });

  test('apply：键不对 400、视频键 422、书不存在 404、候选不存在 404、没给 id 400', () async {
    Future<Object?> apply(String key, Map<String, Object?> body) => call(
      'POST',
      '$kBookMetadataCtlItems/:key/scrape',
      params: <String, String>{'key': key},
      body: body,
    );
    await seedBook(db, '犬');
    expect(() => apply('猫', <String, Object?>{'id': '11'}), _ctlFailure(400));
    expect(
      () => apply('video:v1', <String, Object?>{'id': '11'}),
      _ctlFailure(422),
    );
    expect(
      () => apply('book:没有', <String, Object?>{'id': '11'}),
      _ctlFailure(404),
    );
    expect(
      () => apply('book:犬', <String, Object?>{'id': '999'}),
      _ctlFailure(404),
    );
    expect(() => apply('book:犬', const <String, Object?>{}), _ctlFailure(400));
    expect(
      () => apply('book:犬', <String, Object?>{
        'id': '11',
        'fields': <String>['isbn'],
      }),
      _ctlFailure(400),
    );
  });

  test('apply：只要作者但候选没有作者 → 422（什么也没写）', () async {
    await seedBook(db, '鸟');
    expect(
      () => call(
        'POST',
        '$kBookMetadataCtlItems/:key/scrape',
        params: <String, String>{'key': 'book:鸟'},
        body: <String, Object?>{
          'id': '11',
          'fields': <String>['author'],
        },
      ),
      _ctlFailure(422),
    );
  });

  test('楽天：设置里没填凭据 → 422，不造门面；填齐后把凭据交给门面', () async {
    final List<RakutenBooksCredentials?> handed = <RakutenBooksCredentials?>[];
    final BookMetadataFacadeFactory offline = bookMetadataFacadeFactory;
    bookMetadataFacadeFactory = ({RakutenBooksCredentials? rakuten}) {
      handed.add(rakuten);
      return offline(rakuten: rakuten);
    };
    expect(
      () => call(
        'GET',
        kBookMetadataCtlSearch,
        query: <String, String>{'query': 'x', 'source': 'rakuten'},
      ),
      _ctlFailure(422),
    );
    expect(
      () => call(
        'GET',
        '$kBookMetadataCtlSearch/:source/:id',
        params: <String, String>{'source': 'rakuten', 'id': '9784480432292'},
      ),
      _ctlFailure(422),
    );
    expect(handed, isEmpty);

    await model.prefsRepo.setBookScrapeRakutenApplicationId(' app ');
    await model.prefsRepo.setBookScrapeRakutenAccessKey('pk_x');
    // 其余源照常可用，且同样拿到本机凭据（楽天之外忽略）。
    await call(
      'GET',
      kBookMetadataCtlSearch,
      query: <String, String>{'query': '四叶'},
    );
    expect(handed.single?.applicationId, 'app');
    expect(handed.single?.accessKey, 'pk_x');
  });

  test('openbd：query 里没有 ISBN → 400', () async {
    expect(
      () => call(
        'GET',
        kBookMetadataCtlSearch,
        query: <String, String>{'query': '薬屋のひとりごと', 'source': 'openbd'},
      ),
      _ctlFailure(400),
    );
  });

  test('新源名都认（大小写不敏感），未知源 400', () async {
    expect(BookScrapeSource.tryParse('AniList'), BookScrapeSource.anilist);
    expect(BookScrapeSource.tryParse('ndl'), BookScrapeSource.ndl);
    expect(BookScrapeSource.tryParse('openbd'), BookScrapeSource.openbd);
    expect(BookScrapeSource.tryParse('rakuten'), BookScrapeSource.rakuten);
    expect(BookScrapeSource.tryParse('google'), isNull);
  });

  test('AI 操作描述的 source 值域与 BookScrapeSource 一致', () {
    expect(kBookScrapeSourceNames, <String>[
      for (final BookScrapeSource s in BookScrapeSource.values) s.name,
    ]);
  });

  test('候选线上形状带 publisher / series / volume / isbn / bannerUrl', () {
    final Map<String, Object?> json = bookScrapeCandidateJson(
      const BookScrapeCandidate(
        subjectId: '99026',
        title: '薬屋のひとりごと',
        coverUrl: 'https://example.test/c.jpg',
        source: BookScrapeSource.anilist,
        publisher: 'P',
        series: 'S',
        volume: '1',
        isbn: '9784480432292',
        bannerUrl: 'https://example.test/b.jpg',
      ),
    );
    expect(json['source'], 'anilist');
    expect(json['publisher'], 'P');
    expect(json['series'], 'S');
    expect(json['volume'], '1');
    expect(json['isbn'], '9784480432292');
    expect(json['bannerUrl'], 'https://example.test/b.jpg');
    expect(json['detailUrl'], 'https://anilist.co/manga/99026');
  });
}
