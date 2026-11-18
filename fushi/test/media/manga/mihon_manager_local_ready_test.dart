// MihonManager 初始化拆两段（优化清单 manga-1）：
// - `ensureLocalReady()`：建目录 + 读库 + 回收预览，不发网络；在线阅读只等它。
// - `initialise()`：本地就绪 + 刷新仓库目录（BUG-1340 的语义不变）。
// - 两段失败都不缓存 Future，下一次调用重跑。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

const String _kRepo = 'https://repo.example/index.pb';
const String _kPackage = 'org.example.mangadex';

void main() {
  late Directory temp;
  late FushiDatabase database;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fushi-mihon-local-ready-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> seedStoreAndSource() async {
    await database.upsertMangaExtensionStore(
      MangaExtensionStoresCompanion.insert(
        indexUrl: _kRepo,
        name: 'Repo',
        format: MihonStoreFormat.currentProtobuf.name,
        sortOrder: const Value<int>(0),
      ),
    );
    await database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: _kPackage,
        name: 'MangaDex',
        versionCode: 1,
        versionName: '1',
        libVersion: '1.5',
        language: 'all',
        apkPath: 'mangadex.apk',
        apkSha256: 'x',
        signerSha256: 'y',
        installedAt: 0,
      ),
    );
    await database.replaceMangaOnlineSources(
      _kPackage,
      <MangaOnlineSourcesCompanion>[
        for (final (String id, String language) in <(String, String)>[
          ('1', 'ja'),
          ('3', 'en'),
        ])
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: _kPackage,
            sourceId: id,
            name: 'Source $id',
            language: language,
          ),
      ],
    );
  }

  test('本地就绪不等仓库索引：ensureLocalReady 先完成，initialise 等到目录回来', () async {
    await seedStoreAndSource();
    final _GatedStoreClient client = _GatedStoreClient();
    final MihonManager manager = MihonManager(
      database: database,
      rootDirectory: temp,
      runtime: _NoopRuntime(),
      storeClient: client,
    );
    addTearDown(manager.dispose);

    bool initialised = false;
    final Future<void> full = manager.initialise().then((_) {
      initialised = true;
    });
    await manager.ensureLocalReady();

    expect(manager.installed.single.packageName, _kPackage);
    expect(manager.sources, hasLength(2));
    await client.requested.future;
    expect(initialised, isFalse, reason: '仓库索引还挂着，完整初始化不能提前完成');
    expect(manager.available, isEmpty);
    expect(manager.loading, isTrue);

    client.release.complete();
    await full;
    expect(manager.available.single.packageName, 'org.example.rawkuma');
    expect(manager.loading, isFalse);
    expect(client.fetchCount, 1);

    // 两段都只跑一次：再调拿到的是同一份已完成的结果，不重拉索引。
    await manager.initialise();
    await manager.ensureLocalReady();
    expect(client.fetchCount, 1);
  });

  test('在线阅读取源上下文只等本地就绪，仓库索引挂着也能返回', () async {
    await seedStoreAndSource();
    final _GatedStoreClient client = _GatedStoreClient();
    final MihonManager manager = MihonManager(
      database: database,
      rootDirectory: temp,
      runtime: _NoopRuntime(),
      storeClient: client,
    );
    addTearDown(manager.dispose);
    // 与真实 app 一致：manager 一建就后台跑完整初始化。
    final Future<void> full = manager.initialise();

    const OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: _kPackage,
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/manga/x',
        title: 'Fixture',
        raw: <String, Object?>{},
      ),
      chapters: <OnlineMangaChapter>[],
    );
    // siblingOf 内部走 `_context`（与 resolveChapterPages / fetchCover 同一入口）。
    final ({OnlineMangaRuntimeAdapter adapter, OnlineMangaLibraryEntry seed})
    handle = await MihonLibraryAdapter(manager).siblingOf(
      entry,
      const OnlineMangaSiblingSource(
        sourceId: '3',
        name: 'Source 3',
        language: 'en',
      ),
    );
    expect(handle.seed.sourceId, '3');
    expect(client.release.isCompleted, isFalse);
    await client.requested.future;

    client.release.complete();
    await full;
  });

  test('本地段失败不缓存：修好后再调能成功', () async {
    // 根目录位置上先放一个普通文件 → 建目录必失败。
    final String rootPath = p.join(temp.path, 'mihon');
    await File(rootPath).writeAsString('not a directory');
    final _GatedStoreClient client = _GatedStoreClient()..release.complete();
    final MihonManager manager = MihonManager(
      database: database,
      rootDirectory: Directory(rootPath),
      runtime: _NoopRuntime(),
      storeClient: client,
    );
    addTearDown(manager.dispose);

    await expectLater(manager.ensureLocalReady(), throwsA(isA<IOException>()));
    await expectLater(manager.initialise(), throwsA(isA<IOException>()));
    expect(manager.error, isNotNull);
    expect(manager.loading, isFalse);

    await File(rootPath).delete();
    await seedStoreAndSource();
    await manager.ensureLocalReady();
    expect(manager.installed.single.packageName, _kPackage);
    await manager.initialise();
    expect(manager.error, isNull, reason: '重跑成功后不留上一次的错误');
    expect(manager.available.single.packageName, 'org.example.rawkuma');
    expect(await Directory(p.join(rootPath, 'extensions')).exists(), isTrue);
  });

  test('第一次本地就绪回收上次进程的残留：预览标记与暂存 APK 被清掉', () async {
    final Directory tmp = Directory(p.join(temp.path, 'tmp'));
    await tmp.create(recursive: true);
    final File marker = File(p.join(tmp.path, 'preview-pending'));
    final File staged = File(p.join(tmp.path, 'extension-abc.apk.part'));
    await marker.writeAsString('org.example.orphan');
    await staged.writeAsBytes(<int>[1, 2, 3]);
    final MihonManager manager = MihonManager(
      database: database,
      rootDirectory: temp,
      runtime: _NoopRuntime(),
      storeClient: _GatedStoreClient(),
    );
    addTearDown(manager.dispose);

    await manager.ensureLocalReady();

    expect(await marker.exists(), isFalse);
    expect(await staged.exists(), isFalse);
  });

  test('本地段失败后的重跑不碰在途预览标记与正在落盘的暂存 APK', () async {
    final String rootPath = p.join(temp.path, 'mihon');
    await File(rootPath).writeAsString('not a directory');
    final MihonManager manager = MihonManager(
      database: database,
      rootDirectory: Directory(rootPath),
      runtime: _NoopRuntime(),
      storeClient: _GatedStoreClient(),
    );
    addTearDown(manager.dispose);
    await expectLater(manager.ensureLocalReady(), throwsA(isA<IOException>()));

    // 运行期：目录修好了，用户开始预览 / 安装——标记与 .apk.part 是在途产物，
    // 不是上次进程的残留。
    await File(rootPath).delete();
    final Directory tmp = Directory(p.join(rootPath, 'tmp'));
    await tmp.create(recursive: true);
    final File marker = File(p.join(tmp.path, 'preview-pending'));
    final File staged = File(p.join(tmp.path, 'extension-abc.apk.part'));
    await marker.writeAsString('org.example.previewing');
    await staged.writeAsBytes(<int>[1, 2, 3]);
    await seedStoreAndSource();

    await manager.ensureLocalReady();

    expect(manager.installed.single.packageName, _kPackage, reason: '重跑仍读库');
    expect(await marker.readAsString(), 'org.example.previewing');
    expect(await staged.exists(), isTrue);
  });
}

/// 仓库索引请求挂在 [release] 上，模拟连不上 / 很慢的仓库。
class _GatedStoreClient extends Fake implements MihonExtensionStoreClient {
  final Completer<void> requested = Completer<void>();
  final Completer<void> release = Completer<void>();
  int fetchCount = 0;

  @override
  Future<MihonStoreFetchResult> fetchStore(
    String rawUrl, {
    String? etag,
    String? lastModified,
    bool allowInsecure = false,
  }) async {
    fetchCount++;
    if (!requested.isCompleted) requested.complete();
    await release.future;
    return MihonStoreFetchResult(
      store: MihonStore(
        indexUrl: rawUrl,
        name: 'Repo',
        badgeLabel: '',
        signingKey: 'aabb',
        contact: const <String, String?>{},
        format: MihonStoreFormat.currentProtobuf,
        extensionListUrl: null,
        embeddedExtensions: <MihonAvailableExtension>[
          MihonAvailableExtension(
            storeUrl: rawUrl,
            name: 'Rawkuma',
            packageName: 'org.example.rawkuma',
            apkUrl: '$rawUrl/rawkuma.apk',
            iconUrl: '',
            libVersion: '1.6',
            extensionVersionCode: 1,
            versionName: '1.6.1',
            language: 'ja',
            contentWarning: 0,
            sources: const <MihonAvailableSource>[],
          ),
        ],
      ),
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<MihonAvailableExtension>> fetchExtensions(
    MihonStore store, {
    bool allowInsecure = false,
  }) async => store.embeddedExtensions;

  @override
  void close() {}
}

class _NoopRuntime extends Fake implements MihonRuntime {
  @override
  Future<void> dispose() async {}
}
