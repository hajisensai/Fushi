import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hibiki_cover_meta_');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  String metaPath() => p.join(tmp.path, 'cover_meta.json');
  String corruptPath() => p.join(tmp.path, 'cover_meta.json.corrupt');

  test('set/get/remove/all roundtrip', () async {
    final CoverMetaStore store = CoverMetaStore(tmp);

    // 未记录返回 null（上层视同 autoFrame）。
    expect(await store.get('book-1'), isNull);

    const CoverMeta manual = CoverMeta(origin: CoverOrigin.manual);
    const CoverMeta scraped = CoverMeta(
      origin: CoverOrigin.scraped,
      source: ScrapeSource.bangumi,
      entryId: '325285',
    );

    await store.set('book-1', manual);
    await store.set('book-2', scraped);

    final CoverMeta? got1 = await store.get('book-1');
    expect(got1, isNotNull);
    expect(got1!.origin, CoverOrigin.manual);

    final CoverMeta? got2 = await store.get('book-2');
    expect(got2!.origin, CoverOrigin.scraped);
    expect(got2.source, ScrapeSource.bangumi);
    expect(got2.entryId, '325285');

    final Map<String, CoverMeta> all = await store.all();
    expect(all.keys, containsAll(<String>['book-1', 'book-2']));

    // all() 返回快照，改副本不影响内部缓存。
    all.remove('book-1');
    expect(await store.get('book-1'), isNotNull);

    await store.remove('book-1');
    expect(await store.get('book-1'), isNull);
    expect((await store.all()).keys, <String>['book-2']);
  });

  test('重启（新实例）后仍读到持久化数据', () async {
    final CoverMetaStore first = CoverMetaStore(tmp);
    await first.set(
      'book-x',
      const CoverMeta(
        origin: CoverOrigin.sidecar,
        entryId: 'tmdb-1',
      ),
    );

    // 全新实例，缓存为空，必须从磁盘重新加载。
    final CoverMetaStore second = CoverMetaStore(tmp);
    final CoverMeta? got = await second.get('book-x');
    expect(got, isNotNull);
    expect(got!.origin, CoverOrigin.sidecar);
    expect(got.entryId, 'tmdb-1');
  });

  test('损坏 JSON → 当空重建 + 保留 .corrupt 备份', () async {
    await File(metaPath()).writeAsString('{ this is : not json ]');

    final CoverMetaStore store = CoverMetaStore(tmp);

    // 不抛出，当空处理。
    expect(await store.get('anything'), isNull);
    expect(await store.all(), isEmpty);

    // 损坏原文件被搬到 .corrupt。
    expect(await File(corruptPath()).exists(), isTrue);

    // 后续写入正常产出合法 JSON。
    await store.set('book-1', const CoverMeta(origin: CoverOrigin.manual));
    final Object? decoded = jsonDecode(await File(metaPath()).readAsString());
    expect(decoded, isA<Map<String, Object?>>());
    expect((decoded as Map)['book-1'], isNotNull);
  });

  test('文件缺失当空，不抛出', () async {
    final CoverMetaStore store = CoverMetaStore(tmp);
    expect(await store.all(), isEmpty);
    expect(await File(metaPath()).exists(), isFalse);
  });

  test('并发多次 set 后文件仍是合法 JSON', () async {
    final CoverMetaStore store = CoverMetaStore(tmp);

    await Future.wait<void>(<Future<void>>[
      for (int i = 0; i < 20; i++)
        store.set(
          'book-$i',
          CoverMeta(
            origin: CoverOrigin.scraped,
            source: ScrapeSource.tmdb,
            entryId: '$i',
          ),
        ),
    ]);

    final String raw = await File(metaPath()).readAsString();
    final Object? decoded = jsonDecode(raw);
    expect(decoded, isA<Map<String, Object?>>());

    // 重新加载应能读到全部 20 条。
    final Map<String, CoverMeta> reloaded = await CoverMetaStore(tmp).all();
    expect(reloaded.length, 20);
    for (int i = 0; i < 20; i++) {
      expect(reloaded['book-$i']!.entryId, '$i');
    }
  });
}
