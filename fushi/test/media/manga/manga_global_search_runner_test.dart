import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_global_search_runner.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';

const MangaOnlineSourceRow _row = MangaOnlineSourceRow(
  mediaKind: 'manga',
  extensionPackage: 'pkg',
  sourceId: '1',
  name: 'Good',
  language: 'en',
  baseUrl: 'https://example.com',
  enabled: true,
  pinned: false,
  sortOrder: 0,
);

void main() {
  test('Mihon 宿主缺失按普通错误落 error（不是 CF），每源回调一次', () async {
    final List<MangaSourceSearchRun> runs = <MangaSourceSearchRun>[
      MangaSourceSearchRun(const MihonGlobalSource(_row)),
    ];
    int updates = 0;
    await MangaGlobalSearchRunner(mihonManager: null).search(
      runs: runs,
      query: 'q',
      isCancelled: () => false,
      onRunUpdated: () => updates++,
    );
    expect(runs.single.status, MangaSearchRunStatus.error);
    expect(runs.single.error, isNotNull);
    expect(updates, 1);
  });

  test('取消后不再改写运行态也不再回调', () async {
    final List<MangaSourceSearchRun> runs = <MangaSourceSearchRun>[
      MangaSourceSearchRun(const MihonGlobalSource(_row)),
    ];
    int updates = 0;
    await MangaGlobalSearchRunner(mihonManager: null).search(
      runs: runs,
      query: 'q',
      isCancelled: () => true,
      onRunUpdated: () => updates++,
    );

    expect(runs.single.status, MangaSearchRunStatus.loading);
    expect(updates, 0);
  });

  test('取消后还在排队的源不再发请求（优化清单 manga-17c）', () async {
    final FushiDatabase database = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    final Directory root = await Directory.systemTemp.createTemp(
      'fushi-global-search-',
    );
    final _CountingRuntime runtime = _CountingRuntime();
    final MihonManager manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
    );
    addTearDown(() async {
      manager.dispose();
      await database.close();
      await root.delete(recursive: true);
    });
    await database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: 'pkg',
        name: 'Pkg',
        versionCode: 1,
        versionName: '1',
        libVersion: '1.5',
        language: 'all',
        apkPath: 'pkg.apk',
        apkSha256: 'x',
        signerSha256: 'y',
        installedAt: 0,
      ),
    );
    await manager.reload();

    final List<MangaSourceSearchRun> runs = <MangaSourceSearchRun>[
      for (int i = 0; i < 4; i++)
        MangaSourceSearchRun(const MihonGlobalSource(_row)),
    ];
    bool cancelled = false;
    int updates = 0;
    // 第一个源的请求一发出，这一轮就被取消（用户换了关键词）。
    runtime.onSearch = () => cancelled = true;
    await MangaGlobalSearchRunner(mihonManager: manager).search(
      runs: runs,
      query: 'q',
      isCancelled: () => cancelled,
      onRunUpdated: () => updates++,
      maxConcurrent: 1,
    );

    expect(runtime.searches, 1, reason: '排在后面的三个源不该再打出去');
    expect(
      runs.map((MangaSourceSearchRun run) => run.status),
      everyElement(MangaSearchRunStatus.loading),
    );
    expect(updates, 0);
  });

  test('isCloudflareError：类型化挑战包在 cause 链里也认（优化清单 manga-17d）', () {
    final MihonCloudflareChallengeException challenge =
        MihonCloudflareChallengeException(Uri.parse('https://example.com'));
    // 类型化异常的文案里没有「Cloudflare」这个大小写形态，只按文案会落到 error。
    expect(challenge.toString().contains('Cloudflare'), isFalse);
    expect(MangaGlobalSearchRunner.isCloudflareError(challenge), isTrue);
    expect(
      MangaGlobalSearchRunner.isCloudflareError(
        MihonRuntimeException('SEARCH_FAILED', 'wrapped', cause: challenge),
      ),
      isTrue,
    );
    expect(
      MangaGlobalSearchRunner.isCloudflareError(
        OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'wrapped',
          cause: challenge,
        ),
      ),
      isTrue,
    );
    expect(
      MangaGlobalSearchRunner.isCloudflareError(
        const MihonRuntimeException('SOURCE_HTTP_500', 'Manga source failed'),
      ),
      isFalse,
    );
  });

  test('isCloudflareError：按文案判型', () {
    expect(
      MangaGlobalSearchRunner.isCloudflareError(
        Exception('blocked by Cloudflare'),
      ),
      isTrue,
    );
    expect(
      MangaGlobalSearchRunner.isCloudflareError(Exception('timeout')),
      isFalse,
    );
  });
}

class _CountingRuntime extends Fake implements MihonRuntime {
  int searches = 0;
  void Function()? onSearch;

  @override
  Future<MihonMangaPage> search(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    required String query,
    List<MihonFilter> filters = const <MihonFilter>[],
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    searches++;
    onSearch?.call();
    return const MihonMangaPage(items: <MihonManga>[], hasNextPage: false);
  }

  @override
  Future<void> dispose() async {}
}
