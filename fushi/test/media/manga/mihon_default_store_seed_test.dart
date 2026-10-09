// 扩展仓库**不内置**（2026-10-09 用户口径：「扩展仓库内置仓库全部不内置」）。
//
// 文件名沿用旧的「默认仓库装配」测试（BUG-1717 / BUG-1722 / BUG-2641 的记录指向
// 这里）。守的不变量换成：
// 1. 全新安装：漫画 / 视频两个生态初始化后仓库列表都为空，也不发任何索引请求；
// 2. 存量：旧版本首启落库的默认仓库行是普通记录——升级后原样保留、照常刷新（已装
//    扩展继续能检查更新），用户删掉后重启不会被塞回来；
// 3. 源码里不再有写死的默认仓库地址，也没有首启装配开关。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
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

  MihonManager build(
    MihonExtensionStoreClient client, {
    MihonMediaKind kind = MihonMediaKind.manga,
  }) =>
      MihonManager(
        database: database,
        rootDirectory: root,
        runtime: _SeedRuntime(),
        storeClient: client,
        kind: kind,
      );

  Future<void> insertLegacySeededRow(
    String url, {
    String mediaKind = 'manga',
    String name = 'Keiyoushi',
  }) =>
      database.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: url,
          mediaKind: Value(mediaKind),
          name: name,
          format: MihonStoreFormat.currentProtobuf.name,
          sortOrder: const Value(0),
        ),
      );

  for (final MihonMediaKind kind in MihonMediaKind.values) {
    test('全新安装（${kind.name}）：仓库列表为空，不请求任何索引', () async {
      final _FakeStoreClient client = _FakeStoreClient();
      final MihonManager manager = build(client, kind: kind);
      addTearDown(manager.dispose);

      await manager.initialise();

      expect(manager.stores, isEmpty);
      expect(manager.available, isEmpty);
      expect(client.fetchedStoreUrls, isEmpty);
      expect(manager.error, isNull);
    });
  }

  test('存量：旧版本首启落库的默认仓库原样保留并照常刷新，删掉后重启不回来', () async {
    // 旧版本的状态：默认仓库是一行普通记录 + 「已装配」偏好位。
    await insertLegacySeededRow(_kLegacyMangaRepo);
    await database.setPrefTyped<bool>('mihon_default_store_seeded', true);

    final _FakeStoreClient client = _FakeStoreClient();
    final MihonManager first = build(client);
    await first.initialise();

    expect(
      first.stores.map((MangaExtensionStoreRow row) => row.indexUrl),
      <String>[_kLegacyMangaRepo],
      reason: '存量仓库是用户的数据，升级不得删除',
    );
    expect(client.fetchedStoreUrls, <String>[_kLegacyMangaRepo]);
    expect(
      first.available.map((MihonAvailableExtension item) => item.packageName),
      contains('org.example.rawkuma'),
      reason: '已装扩展仍有来源目录，可以检查更新',
    );

    await first.removeStore(_kLegacyMangaRepo);
    expect(first.stores, isEmpty);
    first.dispose();

    final _FakeStoreClient second = _FakeStoreClient();
    final MihonManager manager = build(second);
    addTearDown(manager.dispose);
    await manager.initialise();

    expect(manager.stores, isEmpty);
    expect(second.fetchedStoreUrls, isEmpty);
  });

  test('存量：旧版本装配偏好位未置位也不会补种任何仓库', () async {
    await database.setPrefTyped<bool>('mihon_default_store_seeded', false);
    await database.setPrefTyped<bool>(
      'mihon_default_anime_store_seeded',
      false,
    );
    final MihonManager manga = build(_FakeStoreClient());
    final MihonManager anime =
        build(_FakeStoreClient(), kind: MihonMediaKind.anime);
    addTearDown(manga.dispose);
    addTearDown(anime.dispose);

    await manga.initialise();
    await anime.initialise();

    expect(manga.stores, isEmpty);
    expect(anime.stores, isEmpty);
  });

  // BUG-2641：默认视频仓库的入口是 legacy `index.min.json`，解析器会跟到同目录
  // `repo.json` 并以后者为身份。旧 _refreshStores 按解析后的地址落库却不删种子行，
  // 于是两行指向同一仓库，之后每次刷新各拉一遍——扩展页每个扩展出现两次（512 = 2×256）。
  group('BUG-2641 入口被解析到另一地址时仓库行收敛为一行', () {
    MihonManager buildAnime(MihonExtensionStoreClient client) => MihonManager(
          database: database,
          rootDirectory: root,
          runtime: _SeedRuntime(),
          storeClient: client,
          kind: MihonMediaKind.anime,
        );

    test('入口行 + 再刷新：只剩解析后的一行，扩展不重复', () async {
      // 旧版本首启落下的入口行（legacy `index.min.json`）。
      await insertLegacySeededRow(
        _kLegacyAnimeRepo,
        mediaKind: 'anime',
        name: 'Yūzōnō',
      );
      final _HoppingStoreClient client = _HoppingStoreClient();
      final MihonManager manager = buildAnime(client);
      addTearDown(manager.dispose);

      await manager.initialise();
      await manager.refreshStores();
      await manager.refreshStores();

      expect(
        manager.stores.map((MangaExtensionStoreRow row) => row.indexUrl),
        <String>[_kResolvedAnimeRepo],
      );
      expect(manager.stores.single.mediaKind, 'anime');
      expect(
        manager.available.map((MihonAvailableExtension e) => e.packageName),
        <String>['org.example.anidb'],
      );
    });

    test('已被旧版本写出两行的库：刷新一次即删掉别名行、列表不再翻倍', () async {
      int order = 0;
      for (final String url in <String>[
        _kLegacyAnimeRepo,
        _kResolvedAnimeRepo,
      ]) {
        await database.upsertMangaExtensionStore(
          MangaExtensionStoresCompanion.insert(
            indexUrl: url,
            mediaKind: const Value('anime'),
            name: 'Yūzōnō',
            format: MihonStoreFormat.legacy.name,
            sortOrder: Value(order++),
          ),
        );
      }
      await database.setPrefTyped<bool>(
        'mihon_default_anime_store_seeded',
        true,
      );
      final MihonManager manager = buildAnime(_HoppingStoreClient());
      addTearDown(manager.dispose);

      await manager.initialise();

      expect(
        manager.stores.map((MangaExtensionStoreRow row) => row.indexUrl),
        <String>[_kResolvedAnimeRepo],
      );
      expect(manager.available, hasLength(1));
    });

    test('翻倍期间用户停用了 repo.json 那行：收敛后仓库仍在且启用，不会整个消失', () async {
      // 用户看到每个扩展两条，停用其中一行来去重——停的恰是解析后的那行。
      await database.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: _kLegacyAnimeRepo,
          mediaKind: const Value('anime'),
          name: 'Yūzōnō',
          format: MihonStoreFormat.legacy.name,
          sortOrder: const Value(0),
        ),
      );
      await database.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: _kResolvedAnimeRepo,
          mediaKind: const Value('anime'),
          name: 'Yūzōnō',
          format: MihonStoreFormat.legacy.name,
          enabled: const Value(false),
          sortOrder: const Value(1),
        ),
      );
      await database.setPrefTyped<bool>(
        'mihon_default_anime_store_seeded',
        true,
      );
      final MihonManager manager = buildAnime(_HoppingStoreClient());
      addTearDown(manager.dispose);

      await manager.initialise();

      expect(
        manager.stores.map((MangaExtensionStoreRow row) => row.indexUrl),
        <String>[_kResolvedAnimeRepo],
      );
      expect(manager.stores.single.enabled, isTrue);
      expect(manager.available, hasLength(1), reason: '仓库仍在、扩展仍可见');
    });
  });

  test('源码守卫：Mihon 管理器不再写死默认仓库地址，也没有首启装配开关', () {
    final String managerSource = maskComments(
      File(p.join(
              'lib', 'src', 'media', 'manga', 'mihon', 'mihon_manager.dart'))
          .readAsStringSync(),
    );
    final String appModelSource = maskComments(
      File(p.join('lib', 'src', 'models', 'app_model.dart')).readAsStringSync(),
    );
    for (final String source in <String>[managerSource, appModelSource]) {
      expect(source, isNot(contains('keiyoushi/extensions')));
      expect(source, isNot(contains('yuzono/anime-repo')));
      expect(source, isNot(contains('seedDefaultStore')));
    }
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
          extensionVersionCode: 1,
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

const String _kLegacyMangaRepo =
    'https://github.com/keiyoushi/extensions/raw/repo/index.pb';

const String _kLegacyAnimeRepo =
    'https://raw.githubusercontent.com/yuzono/anime-repo/repo/index.min.json';

const String _kResolvedAnimeRepo =
    'https://raw.githubusercontent.com/yuzono/anime-repo/repo/repo.json';

/// 模拟 legacy 仓库：请求 `index.min.json` 时解析器跟到 `repo.json` 并以它为身份。
class _HoppingStoreClient extends Fake implements MihonExtensionStoreClient {
  @override
  Future<MihonStoreFetchResult> fetchStore(
    String rawUrl, {
    String? etag,
    String? lastModified,
    bool allowInsecure = false,
  }) async =>
      MihonStoreFetchResult(
        store: MihonStore(
          indexUrl: _kResolvedAnimeRepo,
          name: 'Yūzōnō',
          badgeLabel: '',
          signingKey: 'aabb',
          contact: const <String, String?>{},
          format: MihonStoreFormat.legacy,
          extensionListUrl: null,
          embeddedExtensions: const <MihonAvailableExtension>[],
        ),
        etag: null,
        lastModified: null,
      );

  @override
  Future<List<MihonAvailableExtension>> fetchExtensions(
    MihonStore store, {
    bool allowInsecure = false,
  }) async =>
      <MihonAvailableExtension>[
        MihonAvailableExtension(
          storeUrl: store.indexUrl,
          name: 'AniDB',
          packageName: 'org.example.anidb',
          apkUrl: '${store.indexUrl}/anidb.apk',
          iconUrl: '',
          libVersion: '14',
          extensionVersionCode: 1,
          versionName: '14.5',
          language: 'en',
          contentWarning: 1,
          sources: const <MihonAvailableSource>[],
        ),
      ];

  @override
  void close() {}
}

class _SeedRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
