import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/manga_global_search_runner.dart';

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
