import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/manga_global_search_runner.dart';

AidokuInstalledPackage _package(String id, String name) =>
    AidokuInstalledPackage(
      id: id,
      name: name,
      version: 1,
      languages: const <String>['en'],
      requiresWebView: false,
      packagePath: '/$id.aix',
      installedAt: DateTime.utc(2026),
    );

class _FakeRuntime extends Fake implements AidokuRuntime {
  final List<String> searchQueries = <String>[];

  @override
  Future<Map<String, Object?>> search(
    String packagePath, {
    String? query,
    int page = 1,
  }) async {
    searchQueries.add(query ?? '');
    if (packagePath.contains('blocked')) {
      throw const AidokuRuntimeException(
        'CLOUDFLARE_CHALLENGE',
        'Cloudflare challenge blocked this source',
      );
    }
    if (packagePath.contains('empty')) {
      return <String, Object?>{'entries': <Object?>[]};
    }
    return <String, Object?>{
      'entries': <Object?>[
        <String, Object?>{'key': '/one-piece/', 'title': 'One Piece'},
      ],
    };
  }
}

void main() {
  test('逐源扇出：成功/空/CF 各落各的状态，每源完成回调一次', () async {
    final _FakeRuntime runtime = _FakeRuntime();
    final List<MangaSourceSearchRun> runs = <MangaSourceSearchRun>[
      MangaSourceSearchRun(AidokuGlobalSource(_package('en.good', 'Good'))),
      MangaSourceSearchRun(AidokuGlobalSource(_package('en.empty', 'Empty'))),
      MangaSourceSearchRun(
        AidokuGlobalSource(_package('en.blocked', 'Blocked')),
      ),
    ];
    int updates = 0;
    await MangaGlobalSearchRunner(
      mihonManager: null,
      resolveAidokuRuntime: () => runtime,
    ).search(
      runs: runs,
      query: 'one piece',
      isCancelled: () => false,
      onRunUpdated: () => updates++,
    );

    expect(runs[0].status, MangaSearchRunStatus.done);
    expect(runs[0].aidokuItems.single['title'], 'One Piece');
    expect(runs[1].status, MangaSearchRunStatus.empty);
    expect(runs[2].status, MangaSearchRunStatus.cloudflare);
    expect(updates, 3);
    expect(runtime.searchQueries, hasLength(3));
  });

  test('取消后不再改写运行态也不再回调', () async {
    final _FakeRuntime runtime = _FakeRuntime();
    final List<MangaSourceSearchRun> runs = <MangaSourceSearchRun>[
      MangaSourceSearchRun(AidokuGlobalSource(_package('en.good', 'Good'))),
    ];
    int updates = 0;
    await MangaGlobalSearchRunner(
      mihonManager: null,
      resolveAidokuRuntime: () => runtime,
    ).search(
      runs: runs,
      query: 'q',
      isCancelled: () => true,
      onRunUpdated: () => updates++,
    );

    expect(runs.single.status, MangaSearchRunStatus.loading);
    expect(updates, 0);
  });

  test('Aidoku 运行时不可用按普通错误落 error（不是 CF）', () async {
    final List<MangaSourceSearchRun> runs = <MangaSourceSearchRun>[
      MangaSourceSearchRun(AidokuGlobalSource(_package('en.good', 'Good'))),
    ];
    await MangaGlobalSearchRunner(
      mihonManager: null,
      resolveAidokuRuntime: () => null,
    ).search(
      runs: runs,
      query: 'q',
      isCancelled: () => false,
      onRunUpdated: () {},
    );
    expect(runs.single.status, MangaSearchRunStatus.error);
  });

  test('isCloudflareError：结构化错误码与文案兜底', () {
    expect(
      MangaGlobalSearchRunner.isCloudflareError(
        const AidokuRuntimeException('CLOUDFLARE_CHALLENGE', 'x'),
      ),
      isTrue,
    );
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
