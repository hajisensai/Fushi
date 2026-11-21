import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_client.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_rate_gates.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/metadata/book_art_scrape_service.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart'
    show kBookScraperUserAgent;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_book_metadata_routes.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';

import 'book_metadata_test_fixture.dart';

/// 合集每卷封面（`book.art.scrape` / `book.art.clear` / `book.art.remove`）：经
/// `OpInvoker` 以模型身份执行，撤销载荷过 JSON 往返。
List<int> png(int w, int h, {int shade = 0}) => img.encodePng(
  img.Image(width: w, height: h)..clear(img.ColorRgb8(shade, shade, shade)),
);

http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: const <String, String>{'content-type': 'application/json'},
);

Map<String, Object?> _img(String type, String index, int w, int h) =>
    <String, Object?>{
      'id': index.hashCode,
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
          'width': w,
          'height': h,
          'format': 'png',
        },
      },
    };

Map<String, Object?> _series(int id) => <String, Object?>{
  'id': id,
  'state': 'active',
  'title': 'Test Manga',
  'native_title': 'テスト漫画',
  'cover': <String, Object?>{
    'raw': <String, Object?>{
      'url': 'https://images.mangabaka.dev/cover/$id',
      'width': 1200,
      'height': 1800,
    },
  },
  'authors': <String>['Taro'],
  'type': 'manga',
  'content_rating': 'safe',
  'final_volume': '2',
};

Future<http.Response> _offline(http.Request req) async {
  if (req.url.host == 'images.mangabaka.dev') {
    return http.Response.bytes(
      png(12, 18, shade: req.url.path.length),
      200,
      headers: const <String, String>{'content-type': 'image/png'},
    );
  }
  final String path = req.url.path;
  // 系列 200：只在钉死时按 id 直取（换系列的撤销用例）。
  if (path == '/v1/series/200') {
    return _json(<String, Object?>{'data': _series(200)});
  }
  if (path == '/v1/series/search') {
    return _json(<String, Object?>{
      'data': <Object?>[
        <String, Object?>{
          'id': 100,
          'state': 'active',
          'title': 'Test Manga',
          'native_title': 'テスト漫画',
          'cover': <String, Object?>{
            'raw': <String, Object?>{
              'url': 'https://images.mangabaka.dev/cover/100',
              'width': 1200,
              'height': 1800,
            },
          },
          'authors': <String>['Taro'],
          'type': 'manga',
          'content_rating': 'safe',
          'final_volume': '2',
        },
      ],
      'pagination': <String, Object?>{'next': null},
    });
  }
  if (path == '/v1/series/100/images' || path == '/v1/series/200/images') {
    final bool banner = req.url.queryParameters['type'] == 'banner';
    return _json(<String, Object?>{
      'data': banner
          ? <Object?>[_img('banner', '1', 1920, 600)]
          : <Object?>[
              _img('volume', '1', 1200, 1800),
              _img('volume', '2', 1200, 1800),
            ],
      'pagination': <String, Object?>{'next': null},
    });
  }
  return http.Response('unexpected', 404);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory thumbs;
  late BookMetaTestModel model;
  late OpCatalog catalog;
  late OpInvoker invoker;
  late int collectionId;

  setUp(() async {
    BookArtStore.resetForTesting();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    thumbs = await Directory.systemTemp.createTemp('fushi_book_art_undo_');
    model = BookMetaTestModel(db, prefs, thumbs);
    MediaSource.setDatabase(db);
    bookArtServiceFactory = (AppModel app) {
      final MockClient client = MockClient(_offline);
      return BookArtScrapeService(
        database: app.database,
        store: BookArtStore.of(app.thumbnailsDirectory),
        client: client,
        mangaBaka: MangaBakaClient(
          client: client,
          userAgent: kBookScraperUserAgent,
          gates: MangaBakaRateGates(),
        ),
      );
    };
    for (final int v in <int>[1, 2]) {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'k$v',
          title: 'テスト漫画 $v',
          epubPath: '/nonexistent/k$v.cbz',
          extractDir: '/nonexistent/k$v',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1000,
          author: const Value<String?>('Taro'),
          format: const Value<String>('manga'),
        ),
      );
    }
    collectionId = await db.createMediaCollection('テスト漫画');
    await db.addToCollection(collectionId, MediaKind.epub, 'k1');
    await db.addToCollection(collectionId, MediaKind.epub, 'k2');
    final OpContext context = OpContext(ref: BookMetaRef(model));
    catalog = buildAppOpCatalog(context, buildDomainOpRoutes(context));
    invoker = OpInvoker(catalog);
  });

  tearDown(() async {
    bookArtServiceFactory = (AppModel app) => BookArtScrapeService(
      database: app.database,
      store: BookArtStore.of(app.thumbnailsDirectory),
    );
    BookArtStore.resetForTesting();
    await db.close();
    if (thumbs.existsSync()) await thumbs.delete(recursive: true);
  });

  BookArtStore store() => BookArtStore.of(thumbs);

  Future<OpInvocation> run(String id, Map<String, Object?> args) =>
      invoker.invoke(
        id,
        args,
        caller: OpCaller.model,
        captureUndo: true,
        grantedGates: <String>{
          for (final OpParam g in catalog[id]!.spec.gateParams) g.name,
        },
      );

  Future<OpUndoStatus> undo(OpInvocation invocation) async {
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(invocation.undo!.payload))
            as Map<String, Object?>;
    return (await catalog[invocation.op.id]!.undo!.revert(payload)).status;
  }

  test('三条写操作都有描述且可撤销；volumes 是 read', () {
    for (final String id in <String>[
      'book.art.scrape',
      'book.art.clear',
      'book.art.remove',
    ]) {
      expect(catalog[id]!.risk, OpRisk.write, reason: id);
      expect(catalog[id]!.undo, isNotNull, reason: id);
    }
    expect(catalog['book.scrape.volumes']!.risk, OpRisk.read);
  });

  test('dryRun：同结构计划，不写盘', () async {
    final OpInvocation planned = await run('book.art.scrape', <String, Object?>{
      'id': '$collectionId',
      'dryRun': true,
    });
    final Map<Object?, Object?> result = planned.result! as Map;
    expect(result['dryRun'], isTrue);
    expect(
      (result['series']! as List).single,
      containsPair('decision', 'accepted'),
    );
    expect(store().hasCover('k1'), isFalse);
  });

  test('刮削 → 撤销：两卷写入后回到没刮过', () async {
    final OpInvocation scraped = await run('book.art.scrape', <String, Object?>{
      'id': '$collectionId',
    });
    final Map<Object?, Object?> result = scraped.result! as Map;
    expect(result['usesMangaBaka'], isTrue);
    expect(File(store().bannerPathFor('mangabaka_100')).existsSync(), isTrue);
    expect(store().hasCover('k1'), isTrue);
    expect(store().hasCover('k2'), isTrue);
    expect(await undo(scraped), OpUndoStatus.done);
    expect(store().hasCover('k1'), isFalse);
    expect(store().recordFor('k2'), isNull);
    // 这次刮削写的横幅已无人引用：撤销时当场回收，不留孤儿文件。
    expect(File(store().bannerPathFor('mangabaka_100')).existsSync(), isFalse);
  });

  test('单本移除 → 撤销恢复；之后又被改过 → superseded', () async {
    await run('book.art.scrape', <String, Object?>{'id': '$collectionId'});
    final List<int> original = store().coverFileFor('k1')!.readAsBytesSync();

    final OpInvocation removed = await run('book.art.remove', <String, Object?>{
      'key': 'book:k1',
    });
    expect(store().hasCover('k1'), isFalse);
    expect(await undo(removed), OpUndoStatus.done);
    expect(store().coverFileFor('k1')!.readAsBytesSync(), original);

    final OpInvocation cleared = await run('book.art.clear', <String, Object?>{
      'id': '$collectionId',
    });
    expect(((cleared.result! as Map)['removed']! as List), hasLength(2));
    // 清除后用户又刮了一次：撤销不覆盖之后的改动。
    await run('book.art.scrape', <String, Object?>{'id': '$collectionId'});
    expect(await undo(cleared), OpUndoStatus.superseded);
  });

  test('「在线服务」模块关着：刮削被拒，不发请求', () async {
    model.disabled.add(ModuleId.services);
    await expectLater(
      run('book.art.scrape', <String, Object?>{'id': '$collectionId'}),
      throwsA(anything),
    );
    expect(store().hasCover('k1'), isFalse);
  });

  test('清除 → 撤销：横幅一起回来；单本移除后重刮不写回同一张', () async {
    await run('book.art.scrape', <String, Object?>{'id': '$collectionId'});
    expect(store().backdropForCollection(<String>['k1', 'k2']), isNotNull);
    final OpInvocation cleared = await run('book.art.clear', <String, Object?>{
      'id': '$collectionId',
    });
    expect(store().backdropForCollection(<String>['k1', 'k2']), isNull);
    expect(await undo(cleared), OpUndoStatus.done);
    expect(store().backdropForCollection(<String>['k1', 'k2']), isNotNull);

    await run('book.art.remove', <String, Object?>{'key': 'book:k1'});
    await run('book.art.scrape', <String, Object?>{'id': '$collectionId'});
    expect(store().hasCover('k1'), isFalse);
    expect(store().hasCover('k2'), isTrue);
  });

  test('改钉另一个系列 → 撤销：旧系列与旧横幅回来，新横幅当场回收', () async {
    await run('book.art.scrape', <String, Object?>{'id': '$collectionId'});
    final OpInvocation repinned =
        await run('book.art.scrape', <String, Object?>{
          'id': '$collectionId',
          'seriesKey': parseBookSeriesKey('テスト漫画 1')!.key,
          'source': 'mangabaka',
          'seriesId': '200',
        });
    expect(store().recordFor('k1')!.seriesId, '200');
    expect(File(store().bannerPathFor('mangabaka_200')).existsSync(), isTrue);
    // 换系列后旧横幅无人引用，本轮结束已回收。
    expect(File(store().bannerPathFor('mangabaka_100')).existsSync(), isFalse);

    expect(await undo(repinned), OpUndoStatus.done);
    expect(store().recordFor('k1')!.seriesId, '100');
    expect(File(store().bannerPathFor('mangabaka_100')).existsSync(), isTrue);
    expect(File(store().bannerPathFor('mangabaka_200')).existsSync(), isFalse);
  });

  test('钉死系列：seriesId 不是数字 400；系列键不在合集里 404', () async {
    await expectLater(
      run('book.art.scrape', <String, Object?>{
        'id': '$collectionId',
        'seriesKey': 'x',
        'source': 'mangabaka',
        'seriesId': 'abc',
      }),
      throwsA(anything),
    );
    await expectLater(
      run('book.art.scrape', <String, Object?>{
        'id': '$collectionId',
        'seriesKey': 'no-such-series',
        'source': 'mangabaka',
        'seriesId': '100',
      }),
      throwsA(anything),
    );
  });
}
