import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
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
      source: ScrapeSource.anidb,
      entryId: '16498',
    );

    await store.set('book-1', manual);
    await store.set('book-2', scraped);

    final CoverMeta? got1 = await store.get('book-1');
    expect(got1, isNotNull);
    expect(got1!.origin, CoverOrigin.manual);

    final CoverMeta? got2 = await store.get('book-2');
    expect(got2!.origin, CoverOrigin.scraped);
    expect(got2.source, ScrapeSource.anidb);
    expect(got2.entryId, '16498');

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
      const CoverMeta(origin: CoverOrigin.sidecar, entryId: 'tmdb-1'),
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

  test('多个 store 实例并发写入不会用陈旧快照互相覆盖', () async {
    final CoverMetaStore first = CoverMetaStore(tmp);
    final CoverMetaStore second = CoverMetaStore(tmp);
    await Future.wait<void>(<Future<void>>[
      for (int i = 0; i < 20; i++)
        (i.isEven ? first : second).set(
          'multi-$i',
          CoverMeta(
            origin: i.isEven ? CoverOrigin.manual : CoverOrigin.sidecar,
            entryId: '$i',
          ),
        ),
    ]);

    final Map<String, CoverMeta> reloaded = await CoverMetaStore(tmp).all();
    expect(reloaded.length, 20);
    for (int i = 0; i < 20; i++) {
      expect(reloaded['multi-$i']?.entryId, '$i');
    }
    expect(
      await tmp
          .list()
          .where(
            (FileSystemEntity entity) =>
                p.basename(entity.path).contains('cover_meta.json.tmp.'),
          )
          .toList(),
      isEmpty,
    );
  });

  test('条件批量删除不会清掉并发改成手工来源的记录', () async {
    final CoverMetaStore cleanupStore = CoverMetaStore(tmp);
    final CoverMetaStore userStore = CoverMetaStore(tmp);
    await cleanupStore.set(
      'book-1',
      const CoverMeta(origin: CoverOrigin.autoScraped),
    );

    await userStore.set('book-1', const CoverMeta(origin: CoverOrigin.manual));
    await cleanupStore.removeAllWhereOrigin(<String>[
      'book-1',
    ], CoverOrigin.autoScraped);

    expect((await cleanupStore.get('book-1'))?.origin, CoverOrigin.manual);
  });

  test('legacy 清理状态持久化摘要、保护替换物，并对旧版本降级为保护来源', () async {
    final CoverMetaStore store = CoverMetaStore(tmp);
    await store.set(
      'legacy',
      const CoverMeta(
        origin: CoverOrigin.autoScraped,
        source: ScrapeSource.tmdb,
        entryId: '7',
        contentSha256: 'abc123',
      ),
    );

    expect(await store.markAutoScrapedCleanupPending('legacy', 'abc123'), isTrue);
    CoverMeta meta = (await store.get('legacy'))!;
    expect(meta.origin, CoverOrigin.cleanupPending);
    expect(meta.contentSha256, 'abc123');
    final Map<String, Object?> pendingJson = meta.toJson();
    expect(pendingJson['origin'], CoverOrigin.scraped.name);
    expect(pendingJson['cleanupState'], 'pending');
    expect(CoverMeta.fromJson(pendingJson).origin, CoverOrigin.cleanupPending);

    await store.protectLegacyCleanupReplacement('legacy');
    meta = (await store.get('legacy'))!;
    expect(meta.origin, CoverOrigin.cleanupReplacement);
    expect(meta.contentSha256, 'abc123');
    final Map<String, Object?> replacementJson = meta.toJson();
    expect(replacementJson['origin'], CoverOrigin.manual.name);
    expect(replacementJson['cleanupState'], 'replacement');
    expect(
      CoverMeta.fromJson(replacementJson).origin,
      CoverOrigin.cleanupReplacement,
    );

    await store.set(
      'frame',
      const CoverMeta(origin: CoverOrigin.autoScraped),
    );
    expect(await store.allowsAutoFrameWrite('frame'), isTrue);
    expect(
      (await store.get('frame'))!.origin,
      CoverOrigin.autoScraped,
      reason: '写前准入不能让失败的抽帧提前废止旧刮削归属',
    );
    expect(await store.markAutoFrameAfterWrite('frame'), isTrue);
    expect((await store.get('frame'))!.origin, CoverOrigin.autoFrame);

    for (final CoverOrigin protectedOrigin in <CoverOrigin>[
      CoverOrigin.manual,
      CoverOrigin.scraped,
      CoverOrigin.userScraped,
      CoverOrigin.sidecar,
      CoverOrigin.cleanupPending,
      CoverOrigin.cleanupReplacement,
    ]) {
      await store.set('protected', CoverMeta(origin: protectedOrigin));
      expect(await store.allowsAutoFrameWrite('protected'), isFalse);
      expect(await store.markAutoFrameAfterWrite('protected'), isFalse);
      expect((await store.get('protected'))!.origin, protectedOrigin);
    }
  });
}
