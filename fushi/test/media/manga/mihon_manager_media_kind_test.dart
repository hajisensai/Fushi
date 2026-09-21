import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_bridge_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi_core/fushi_core.dart';

/// 漫画与视频两个 manager 共用一个运行时、一套扩展表，按 `media_kind` 分片。
void main() {
  late Directory root;
  late FushiDatabase database;
  late _KindRuntime runtime;
  late MihonManager manga;
  late MihonManager anime;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-mihon-kind-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    runtime = _KindRuntime();
    manga = MihonManager(
      database: database,
      rootDirectory: Directory('${root.path}/mihon'),
      runtime: runtime,
      ownsRuntime: false,
    );
    anime = MihonManager(
      database: database,
      rootDirectory: Directory('${root.path}/mihon_anime'),
      runtime: runtime,
      kind: MihonMediaKind.anime,
      ownsRuntime: false,
    );
    await manga.initialise();
    await anime.initialise();
  });

  tearDown(() async {
    manga.dispose();
    anime.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> install(MihonManager manager, String apkName) async {
    final File apk = File('${root.path}/$apkName')
      ..writeAsBytesSync(Uint8List.fromList(apkName.codeUnits));
    final MihonInstallProposal proposal = await manager.prepareLocalInstall(
      apk.path,
    );
    await manager.commitInstall(proposal, trustSigner: true);
  }

  test('an anime APK is refused by the manga manager and vice versa', () async {
    runtime.inspection = _inspection(MihonMediaKind.anime, libVersion: '14');
    await expectLater(
      () => install(manga, 'anime.apk'),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException e) => e.code,
          'code',
          'WRONG_MEDIA_KIND',
        ),
      ),
    );
    runtime.inspection = _inspection(MihonMediaKind.manga, libVersion: '1.6');
    await expectLater(
      () => install(anime, 'manga.apk'),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException e) => e.code,
          'code',
          'WRONG_MEDIA_KIND',
        ),
      ),
    );
  });

  test('anime lib gate accepts 14 to 16 and refuses 17', () async {
    runtime.inspection = _inspection(MihonMediaKind.anime, libVersion: '17');
    await expectLater(
      () => install(anime, 'lib17.apk'),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException e) => e.code,
          'code',
          'UNSUPPORTED_LIB',
        ),
      ),
    );
    runtime.inspection = _inspection(MihonMediaKind.anime, libVersion: '14');
    await install(anime, 'lib14.apk');
    expect(anime.installed.single.libVersion, '14');
    // 宿主 ABI 是 lib 14 + lib 16 并集（Hoster API、data class Video）：两代都装。
    runtime.inspection = _inspection(
      MihonMediaKind.anime,
      libVersion: '16',
      packageName: 'eu.kanade.tachiyomi.animeextension.all.fixture16',
    );
    await install(anime, 'lib16.apk');
    expect(
      anime.installed.map((MangaExtensionRow e) => e.libVersion).toSet(),
      <String>{'14', '16'},
    );
  });

  test(
    'installs land in the shared tables tagged by kind and each manager only sees its own',
    () async {
      runtime.inspection = _inspection(MihonMediaKind.anime, libVersion: '14');
      await install(anime, 'anime.apk');
      runtime.inspection = _inspection(
        MihonMediaKind.manga,
        libVersion: '1.6',
        packageName: 'eu.kanade.tachiyomi.extension.ja.fixture',
      );
      await install(manga, 'manga.apk');

      // 视频扩展经 sourcesAnime 列源，漫画经 sourcesManga——两条调用面都真的被打到。
      expect(runtime.listedAnime, <String>[
        'eu.kanade.tachiyomi.animeextension.all.fixture',
      ]);
      expect(runtime.listedManga, <String>[
        'eu.kanade.tachiyomi.extension.ja.fixture',
      ]);

      await manga.reload();
      await anime.reload();
      expect(
        anime.installed.map((MangaExtensionRow r) => r.packageName),
        <String>['eu.kanade.tachiyomi.animeextension.all.fixture'],
      );
      expect(anime.installed.single.mediaKind, 'anime');
      expect(anime.sources.single.mediaKind, 'anime');
      expect(
        manga.installed.map((MangaExtensionRow r) => r.packageName),
        <String>['eu.kanade.tachiyomi.extension.ja.fixture'],
      );
      expect(manga.sources.single.mediaKind, 'manga');
      // 不分片的全量读仍能看到两条：列是分片键，不是隔离墙。
      expect((await database.getMangaExtensions()).length, 2);
    },
  );

  test(
    'default store seed is per kind and lands with its media_kind',
    () async {
      final MihonManager seeded = MihonManager(
        database: database,
        rootDirectory: Directory('${root.path}/seeded'),
        runtime: runtime,
        kind: MihonMediaKind.anime,
        ownsRuntime: false,
        seedDefaultStore: true,
        storeClient: _OfflineStoreClient(),
      );
      addTearDown(seeded.dispose);
      await seeded.initialise().catchError((Object _) {});
      final List<MangaExtensionStoreRow> animeStores = await database
          .getMangaExtensionStores(mediaKind: 'anime');
      expect(animeStores.single.indexUrl, kMihonDefaultAnimeStoreIndexUrl);
      expect(animeStores.single.mediaKind, 'anime');
      expect(
        await database.getMangaExtensionStores(mediaKind: 'manga'),
        isEmpty,
      );
      expect(
        await database.getPrefTyped<bool>(
          kMihonDefaultAnimeStoreSeededPref,
          false,
        ),
        isTrue,
      );
      expect(
        await database.getPrefTyped<bool>(kMihonDefaultStoreSeededPref, false),
        isFalse,
      );
    },
  );

  test(
    'a shared runtime is not disposed by a manager that does not own it',
    () async {
      anime.dispose();
      await anime.shutdownRuntimeForExit();
      expect(runtime.disposed, isFalse);
    },
  );
}

MihonExtensionInspection _inspection(
  MihonMediaKind kind, {
  required String libVersion,
  String packageName = 'eu.kanade.tachiyomi.animeextension.all.fixture',
}) => MihonExtensionInspection(
  packageName: packageName,
  name: 'Fixture',
  apkVersionCode: 1,
  versionName: '$libVersion.1',
  libVersion: libVersion,
  signerSha256: 'aabb',
  sourceClasses: const <String>['.Fixture'],
  kind: kind,
);

/// 同时具备漫画与视频调用面的 fake（生产的两个运行时都经 [MihonBridgeRuntime]）。
class _KindRuntime extends MihonBridgeRuntime {
  MihonExtensionInspection inspection = _inspection(
    MihonMediaKind.manga,
    libVersion: '1.6',
  );
  final List<String> listedManga = <String>[];
  final List<String> listedAnime = <String>[];
  bool disposed = false;

  @override
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments, {
    MihonSource? source,
  }) async {
    if (method == 'sourcesManga') listedManga.add(extension.packageName);
    if (method == 'sourcesAnime') listedAnime.add(extension.packageName);
    if (method == 'sourcesManga' || method == 'sourcesAnime') {
      return <Object?>[
        <Object?, Object?>{
          'id': '7',
          'name': 'Fixture source',
          'lang': 'all',
          'baseUrl': 'https://source.example',
        },
      ];
    }
    throw UnimplementedError(method);
  }

  @override
  Future<MihonExtensionInspection> inspectExtension(String apkPath) async =>
      inspection;

  @override
  Future<String> installPrivateExtension(String apkPath) async => apkPath;

  @override
  Future<void> uninstallPrivateExtension(String packageName) async {}

  @override
  Future<void> invalidateExtension(String packageName) async {}

  @override
  Future<void> invalidateExtensions(Iterable<String> packageNames) async {}

  @override
  Future<void> clearSourceData(
    MihonExtensionRef extension,
    MihonSource source,
  ) async {}

  @override
  Future<MihonCapabilities> getCapabilities() => throw UnimplementedError();

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) => throw UnimplementedError();

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) => throw UnimplementedError();

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 种子只往本地写一行；刷新去拉索引时离线失败，不影响种子断言。
class _OfflineStoreClient extends MihonExtensionStoreClient {
  @override
  Future<MihonStoreFetchResult> fetchStore(
    String rawUrl, {
    String? etag,
    String? lastModified,
    bool allowInsecure = false,
  }) async => throw const SocketException('offline');
}
