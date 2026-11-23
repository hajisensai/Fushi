import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_library_scrape_routes.dart';
import 'package:fushi/src/ops/op_context.dart';

import 'book_metadata_test_fixture.dart';

Matcher _ctlFailure(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

/// `library scrape-meta get|set|clear`（v161 条目刮削资料 / 横版背景）的控制通道路由。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory thumbs;
  late Directory images;
  late BookMetaRef ref;
  late List<CtlRoute> routes;

  // 最小 GIF（写侧判据只查头）。
  final List<int> gif = <int>[
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0, 0, 0x3B, //
  ];

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    thumbs = await Directory.systemTemp.createTemp('fushi_item_scrape_');
    images = Directory(p.join(thumbs.path, 'items'));
    ref = BookMetaRef(BookMetaTestModel(db, prefs, thumbs));
    MediaSource.setDatabase(db);
    libraryItemScrapeStoreFactory = (FushiDatabase d) =>
        ItemScrapeStore(d, imagesDirectory: images);
    routes = buildLibraryScrapeCtlRoutes(OpContext(ref: ref));
  });

  tearDown(() async {
    libraryItemScrapeStoreFactory = ItemScrapeStore.new;
    await db.close();
    if (thumbs.existsSync()) await thumbs.delete(recursive: true);
  });

  const String pattern = '$kLibraryScrapeCtlItems/:key/scrape-meta';

  Future<Map<String, Object?>> call(
    String method,
    String key, {
    Map<String, Object?> body = const <String, Object?>{},
  }) async =>
      (await routes
              .singleWhere(
                (CtlRoute r) => r.method == method && r.pattern == pattern,
              )
              .handler(
                CtlCall(
                  method: method,
                  path: pattern,
                  params: <String, String>{'key': key},
                  query: const <String, String>{},
                  body: body,
                ),
              ))!
          as Map<String, Object?>;

  test('set 合并写资料 + 本地背景；get 读回；书键落 (epub, uid)', () async {
    await seedBook(db, '猫');
    final File bg = File(p.join(thumbs.path, 'bg.gif'))..writeAsBytesSync(gif);
    await call(
      'PUT',
      'book:猫',
      body: <String, Object?>{
        'summary': '简介',
        'year': 2014,
        'rating': 8.5,
        'genres': <String>['恋爱', '日常'],
        'backdropPath': bg.path,
      },
    );
    await call('PUT', 'book:猫', body: <String, Object?>{'rating': 9});
    final Map<String, Object?> got = await call('GET', 'book:猫');
    final String uid = (await db.resolveEpubBookUid('猫'))!;
    expect(got['mediaType'], 'epub');
    expect(got['entryKey'], uid);
    final Map<String, Object?> meta = got['meta']! as Map<String, Object?>;
    expect(meta['summary'], '简介', reason: '第二次 set 只改评分');
    expect(meta['airDate'], '2014');
    expect(meta['rating'], 9.0);
    expect(meta['tags'], <String>['恋爱', '日常']);
    expect(meta['source'], 'manual');
    final List<Object?> imgs = got['images']! as List<Object?>;
    final Map<Object?, Object?> backdrop =
        imgs.single! as Map<Object?, Object?>;
    expect(backdrop['kind'], 'backdrop');
    expect(p.isWithin(images.path, '${backdrop['path']}'), isTrue);
    expect(ref.invalidations, greaterThan(0));
  });

  test('v172 字段锁：手填的简介经 replace 照写、锁保留；undo 连锁一起恢复', () async {
    await seedBook(db, '锁');
    final String uid = (await db.resolveEpubBookUid('锁'))!;
    final ItemScrapeKey key = ItemScrapeKey(MediaKind.epub, uid);
    await ItemScrapeStore(db).setManualFields(
      key,
      <ItemScrapeLockableField, String?>{
        ItemScrapeLockableField.summary: '我写的',
      },
    );
    final Map<String, Object?> before = await call('GET', 'book:锁');
    expect((before['meta']! as Map<String, Object?>)['lockedFields'], <String>[
      'summary',
    ]);

    await call(
      'PUT',
      'book:锁',
      body: <String, Object?>{'summary': 'AI 写的', 'replace': true},
    );
    final Map<String, Object?> replaced =
        (await call('GET', 'book:锁'))['meta']! as Map<String, Object?>;
    expect(replaced['summary'], 'AI 写的', reason: '明确替换照写');
    expect(replaced['lockedFields'], <String>['summary'], reason: '锁不被脚本清掉');

    await restoreItemScrapeState(ref.model, 'book:锁', before);
    final Map<String, Object?> undone =
        (await call('GET', 'book:锁'))['meta']! as Map<String, Object?>;
    expect(undone['summary'], '我写的');
    expect(undone['lockedFields'], <String>['summary']);
  });

  test('游戏键；clear 删行和文件；undo 快照恢复执行前状态', () async {
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'g1',
        name: 'G',
        exePath: '/g/1.exe',
        workdir: '/g',
        addedAt: 0,
      ),
    );
    final Map<String, Object?> before = await call('GET', 'game:g1');
    expect(before['meta'], isNull);
    final File bg = File(p.join(thumbs.path, 'g.gif'))..writeAsBytesSync(gif);
    await call(
      'PUT',
      'game:g1',
      body: <String, Object?>{'summary': 's', 'backdropPath': bg.path},
    );
    // 撤销 set：执行前没有资料也没有背景 → 两样都清掉。
    await restoreItemScrapeState(ref.model, 'game:g1', before);
    final Map<String, Object?> undone = await call('GET', 'game:g1');
    expect(undone['meta'], isNull);
    expect(undone['images'], isEmpty);

    await call(
      'PUT',
      'game:g1',
      body: <String, Object?>{'summary': 's', 'backdropPath': bg.path},
    );
    final Map<String, Object?> cleared = await call('DELETE', 'game:g1');
    expect(cleared['cleared'], isTrue);
    expect(await db.getAllItemImages(), isEmpty);
    expect(images.listSync().whereType<File>(), isEmpty, reason: '清除后图片文件回收');
  });

  test('拒绝：视频 422、条目不存在 404、坏评分 / 坏日期 400、相对路径 400、坏图 422', () async {
    await seedBook(db, '犬');
    expect(() => call('GET', 'video:v1'), _ctlFailure(422));
    expect(() => call('GET', 'book:不存在'), _ctlFailure(404));
    expect(() => call('GET', 'game:nope'), _ctlFailure(404));
    expect(
      () => call('PUT', 'book:犬', body: <String, Object?>{'rating': 11}),
      _ctlFailure(400),
    );
    expect(
      () => call('PUT', 'book:犬', body: <String, Object?>{'date': '2014/1'}),
      _ctlFailure(400),
    );
    expect(
      () => call(
        'PUT',
        'book:犬',
        body: <String, Object?>{'backdropPath': 'rel.jpg'},
      ),
      _ctlFailure(400),
    );
    final File bad = File(p.join(thumbs.path, 'bad.jpg'))
      ..writeAsStringSync('<html>');
    await expectLater(
      call('PUT', 'book:犬', body: <String, Object?>{'backdropPath': bad.path}),
      _ctlFailure(422),
    );
  });
}
