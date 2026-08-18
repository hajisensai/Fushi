// 默认扩展仓库自动装配（用户诉求：「漫画扩展仓库默认添加 keiyoushi」）。
//
// 守三条不变量：
// 1. 首次初始化把 [kMihonDefaultStoreIndexUrl] 装进来——不装的话「漫画扩展」一节
//    开箱是空的，用户得先自己知道一个仓库地址；
// 2. **只装一次**——用户删掉它之后重启不会被塞回来（置位 pref
//    [kMihonDefaultStoreSeededPref]）。这条比第 1 条更容易写坏：任何「没有仓库就
//    补一个」的写法都会把用户的删除操作每次启动撤销掉；
// 3. **装配不依赖网络**（BUG-1722）——装配是一次本地 DB 写，连不上 github.com 也
//    照样落地一行，目录由统一的 _refreshStores 去拉、失败写进该行的 lastError。
//    把这两件事绑在一起就是 BUG-1722 的形状：用户手机长期连不上 github，于是一行
//    都写不出来，扩展页永远空着，而「下次启动重试」永远也重试不成。
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
  late FushiDatabase database;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-mihon-seed-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
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

  // BUG-1722 的核心回归。旧实现在种子里直接 `addStore()`，于是「默认仓库存在」被
  // 绑死在「首次启动连得上 github.com」上：连不上就一行都不写，用户看到的是一个
  // 空列表，而且无从知道本该有一个默认仓库；所谓「下次启动重试」在长期连不上的
  // 网络（用户手机就是）下等于永远没有。配置和目录是两件事，配置必须无条件落地。
  test('首次启动连不上也照样有默认仓库：行先落地，失败挂在行上，联网后自动补齐目录', () async {
    final MihonManager offline = build(_FailingStoreClient());
    await offline.initialise();

    expect(
      offline.stores.map((MangaExtensionStoreRow row) => row.indexUrl),
      contains(kMihonDefaultStoreIndexUrl),
      reason: '装配是一次本地 DB 写，不该被网络失败取消掉',
    );
    final MangaExtensionStoreRow seeded = offline.stores.single;
    expect(
      seeded.lastError,
      isNotNull,
      reason: '拉不到目录要让用户在扩展页看见，而不是整个仓库静默消失',
    );
    expect(seeded.lastSyncAt, isNull, reason: '一次都没成功同步过');
    expect(
      offline.error,
      isNull,
      reason: '默认仓库不是用户发起的操作，拉不到不该在扩展页顶上挂一条全局报错',
    );
    expect(
      await database.getPrefTyped<bool>(kMihonDefaultStoreSeededPref, false),
      isTrue,
      reason: '置位语义是「已经替用户装配过」，不是「已经拉到过目录」',
    );
    offline.dispose();

    // 同一个库换成能联网的下一次启动：不重新装配（pref 已置位），但统一的
    // _refreshStores 会把目录补齐、把 lastError 清掉。
    final _FakeStoreClient client = _FakeStoreClient();
    final MihonManager online = build(client);
    addTearDown(online.dispose);
    await online.initialise();

    expect(client.fetchedStoreUrls, <String>[kMihonDefaultStoreIndexUrl]);
    expect(online.stores.single.lastError, isNull);
    expect(online.stores.single.lastSyncAt, isNotNull);
    expect(
      online.available.map((MihonAvailableExtension item) => item.packageName),
      contains('org.example.rawkuma'),
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
