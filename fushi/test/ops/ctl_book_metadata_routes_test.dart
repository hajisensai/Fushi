import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_book_metadata_routes.dart';
import 'package:fushi/src/ops/op_context.dart';

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
    bookMetadataFacadeFactory = () => BookMetadataScrapeFacade(
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

  test('三条路由齐全', () {
    expect(
      <String>[for (final CtlRoute r in routes) '${r.method} ${r.pattern}'],
      <String>[
        'GET /api/admin/book/scrape',
        'GET /api/admin/book/scrape/:source/:id',
        'POST /api/admin/book/items/:key/scrape',
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

  test('apply：默认只换封面；--title 写显示名；结果带快照与封面备份', () async {
    await seedBook(db, '猫');
    final Map<String, Object?> cover =
        (await call(
              'POST',
              '$kBookMetadataCtlItems/:key/scrape',
              params: <String, String>{'key': 'book:猫'},
              body: <String, Object?>{'id': '11'},
            ))!
            as Map<String, Object?>;
    expect(cover['applied'], <String>['cover']);
    expect(((cover['after']! as Map<String, Object?>)['coverSha']), isNotNull);
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
}
