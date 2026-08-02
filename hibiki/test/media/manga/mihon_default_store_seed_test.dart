// 默认扩展仓库自动装配（用户诉求：「漫画扩展仓库默认添加 keiyoushi」）。
//
// 守两条不变量：
// 1. 首次初始化把 [kMihonDefaultStoreIndexUrl] 装进来——不装的话「漫画扩展」一节
//    开箱是空的，用户得先自己知道一个仓库地址；
// 2. **只装一次**——用户删掉它之后重启不会被塞回来（置位 pref
//    [kMihonDefaultStoreSeededPref]）。这条比第 1 条更容易写坏：任何「没有仓库就
//    补一个」的写法都会把用户的删除操作每次启动撤销掉。
//
// 另外守「装不上不致命」：首次启动断网时初始化不得抛，且 pref 不置位（下次再试）。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late Directory root;
  late HibikiDatabase database;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-mihon-seed-');
    database = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  MihonManager build(MihonExtensionStoreClient client) => MihonManager(
        database: database,
        rootDirectory: root,
        runtime: _SeedRuntime(),
        storeClient: client,
      );

  test('首次初始化自动装上 keiyoushi 仓库，且只拉这一个索引', () async {
    final _FakeStoreClient client = _FakeStoreClient();
    final MihonManager manager = build(client);
    addTearDown(manager.dispose);

    await manager.initialise();

    expect(
      manager.stores.map((MangaExtensionStoreRow row) => row.indexUrl),
      contains(kMihonDefaultStoreIndexUrl),
    );
    expect(client.fetchedStoreUrls, <String>[kMihonDefaultStoreIndexUrl]);
    expect(
      await database.getPrefTyped<bool>(kMihonDefaultStoreSeededPref, false),
      isTrue,
    );
  });

  test('用户删掉默认仓库后重启不会被重新塞回来', () async {
    final MihonManager first = build(_FakeStoreClient());
    await first.initialise();
    await first.removeStore(kMihonDefaultStoreIndexUrl);
    expect(first.stores, isEmpty);
    first.dispose();

    final _FakeStoreClient second = _FakeStoreClient();
    final MihonManager manager = build(second);
    addTearDown(manager.dispose);
    await manager.initialise();

    expect(manager.stores, isEmpty);
    expect(second.fetchedStoreUrls, isEmpty);
  });

  test('首次启动拉不到仓库不致命：初始化不抛，pref 不置位，下次还会再试', () async {
    final MihonManager offline = build(_FailingStoreClient());
    await offline.initialise();
    expect(offline.stores, isEmpty);
    expect(
      offline.error,
      isNull,
      reason: '默认仓库不是用户发起的操作，拉不到不该在扩展页挂一条报错',
    );
    expect(
      await database.getPrefTyped<bool>(kMihonDefaultStoreSeededPref, false),
      isFalse,
    );
    offline.dispose();

    final MihonManager online = build(_FakeStoreClient());
    addTearDown(online.dispose);
    await online.initialise();
    expect(
      online.stores.map((MangaExtensionStoreRow row) => row.indexUrl),
      contains(kMihonDefaultStoreIndexUrl),
    );
  });
}

MihonStore _store(String indexUrl) => MihonStore(
      indexUrl: indexUrl,
      name: 'Keiyoushi',
      badgeLabel: '',
      signingKey: 'aabb',
      contact: const <String, String?>{},
      format: MihonStoreFormat.currentJson,
      extensionListUrl: null,
      embeddedExtensions: <MihonAvailableExtension>[
        MihonAvailableExtension(
          storeUrl: indexUrl,
          name: 'RawKuma',
          packageName: 'org.example.rawkuma',
          apkUrl: '$indexUrl/rawkuma.apk',
          iconUrl: '',
          libVersion: '1.6',
          versionCode: 1,
          versionName: '1.6.1',
          language: 'ja',
          contentWarning: 0,
          sources: const <MihonAvailableSource>[],
        ),
      ],
    );

class _FakeStoreClient extends Fake implements MihonExtensionStoreClient {
  final List<String> fetchedStoreUrls = <String>[];

  @override
  Future<MihonStoreFetchResult> fetchStore(
    String rawUrl, {
    String? etag,
    String? lastModified,
    bool allowInsecure = false,
  }) async {
    fetchedStoreUrls.add(rawUrl);
    return MihonStoreFetchResult(
      store: _store(rawUrl),
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<MihonAvailableExtension>> fetchExtensions(
    MihonStore store, {
    bool allowInsecure = false,
  }) async =>
      store.embeddedExtensions;

  @override
  void close() {}
}

class _FailingStoreClient extends Fake implements MihonExtensionStoreClient {
  @override
  Future<MihonStoreFetchResult> fetchStore(
    String rawUrl, {
    String? etag,
    String? lastModified,
    bool allowInsecure = false,
  }) async =>
      throw const SocketException('offline');

  @override
  void close() {}
}

class _SeedRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
