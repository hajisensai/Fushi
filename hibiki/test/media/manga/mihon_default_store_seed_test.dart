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
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../../helpers/source_guard.dart';

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
        seedDefaultStore: true,
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

  // 装默认仓库是**应用启动策略**，不是「构造一个 manager」的语义。挂成 manager
  // 的默认行为，等于让每个构造 manager 的单测都去拉 keiyoushi 的真实索引
  // （1900+ 条）——本轮就是这样把 `mihon_manager_install_test` 那条 cold-start
  // 用例打红的：setUp 里种进来的默认仓库让后续 refresh 多刷了一个仓库。
  test('默认仓库装配默认关闭，只有真实 app 启动那一处打开', () {
    final String managerSource = maskComments(
      File(p.join(
              'lib', 'src', 'media', 'manga', 'mihon', 'mihon_manager.dart'))
          .readAsStringSync(),
    );
    expect(
      managerSource,
      contains('this.seedDefaultStore = false'),
      reason: '构造 manager 不得默认触发网络装配',
    );
    final String appModelSource = maskComments(
      File(p.join('lib', 'src', 'models', 'app_model.dart')).readAsStringSync(),
    );
    expect(
      appModelSource,
      contains('seedDefaultStore: true'),
      reason: '真实 app 启动必须开，否则用户拿不到默认仓库',
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
