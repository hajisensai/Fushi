// 找片渠道「视频 Mihon 源」只等 MihonManager 的本地就绪段（#3722 第 3 节 c09
// 遗留，并入 c28）：列出已启用的 Aniyomi 源只要已装扩展与库里的来源，不需要扩展
// 仓库目录。以前等完整 initialise()，仓库索引挂着时找片一直转圈。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/video/discovery/video_work_acquisition_backends.dart';
import 'package:fushi_core/fushi_core.dart';

const String _kRepo = 'https://repo.example/index.pb';
const String _kPackage = 'org.example.anime';

void main() {
  late Directory temp;
  late FushiDatabase database;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fushi-anime-acq-ready-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('扩展仓库索引挂着时，仍立即列出已启用的视频源', () async {
    const String mediaKind = 'anime';
    await database.upsertMangaExtensionStore(
      MangaExtensionStoresCompanion.insert(
        indexUrl: _kRepo,
        name: 'Repo',
        format: MihonStoreFormat.currentProtobuf.name,
        sortOrder: const Value<int>(0),
        mediaKind: const Value<String>(mediaKind),
      ),
    );
    await database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: _kPackage,
        name: 'AnimeSite',
        versionCode: 1,
        versionName: '1',
        libVersion: '16',
        language: 'ja',
        apkPath: 'anime.apk',
        apkSha256: 'x',
        signerSha256: 'y',
        installedAt: 0,
        mediaKind: const Value<String>(mediaKind),
      ),
    );
    await database
        .replaceMangaOnlineSources(_kPackage, <MangaOnlineSourcesCompanion>[
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: _kPackage,
            sourceId: '7',
            name: 'Anime source',
            language: 'ja',
            mediaKind: const Value<String>(mediaKind),
          ),
        ]);
    final _HangingStoreClient client = _HangingStoreClient();
    final MihonManager manager = MihonManager(
      database: database,
      rootDirectory: temp,
      runtime: _NoopRuntime(),
      storeClient: client,
      kind: MihonMediaKind.anime,
    );
    addTearDown(manager.dispose);
    // 与真实 app 一致：manager 一建就后台跑完整初始化（会卡在仓库索引上）。
    unawaited(manager.initialise().then<void>((_) {}, onError: (Object _) {}));

    // 修复前：这里陪着完整初始化等仓库索引，永远等不到。
    final List<VideoAcquisitionSearchTarget> targets =
        await mihonAnimeAcquisitionTargets(
          manager,
        ).timeout(const Duration(seconds: 5));

    expect(targets.map((VideoAcquisitionSearchTarget t) => t.id), <String>[
      'mihon:$_kPackage:7',
    ]);
    await client.requested.future;
    expect(client.release.isCompleted, isFalse);
  });
}

/// 仓库索引请求永远挂着，模拟连不上 / 很慢的仓库。
class _HangingStoreClient extends Fake implements MihonExtensionStoreClient {
  final Completer<void> requested = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<MihonStoreFetchResult> fetchStore(
    String rawUrl, {
    String? etag,
    String? lastModified,
    bool allowInsecure = false,
  }) async {
    if (!requested.isCompleted) requested.complete();
    await release.future;
    throw const SocketException('unreachable');
  }

  @override
  void close() {}
}

class _NoopRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
