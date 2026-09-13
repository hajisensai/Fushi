import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2481「按下载量排序」的纯函数：计数按包取最大、源按计数降序、无计数排最后、
/// 同分保持原 sortOrder。
MihonAvailableExtension _ext(String packageName, String store, int? count) =>
    MihonAvailableExtension(
      storeUrl: store,
      name: packageName,
      packageName: packageName,
      apkUrl: 'https://$store/$packageName.apk',
      iconUrl: '',
      libVersion: '1.6',
      extensionVersionCode: 1,
      versionName: '1.0',
      language: 'ja',
      contentWarning: 0,
      sources: const <MihonAvailableSource>[],
      downloadCount: count,
    );

MangaOnlineSourceRow _source(String pkg, String id, int sortOrder) =>
    MangaOnlineSourceRow(
      extensionPackage: pkg,
      sourceId: id,
      name: id,
      language: 'ja',
      baseUrl: '',
      enabled: true,
      pinned: false,
      sortOrder: sortOrder,
    );

void main() {
  test('mihonDownloadCountsByPackage：同包多仓库取最大，null 不入表', () {
    final Map<String, int> counts = mihonDownloadCountsByPackage(
      <MihonAvailableExtension>[
        _ext('a', 's1', 100),
        _ext('a', 's2', 900),
        _ext('b', 's1', null),
        _ext('c', 's1', 0),
      ],
    );
    expect(counts, <String, int>{'a': 900, 'c': 0});
  });

  test('sortMangaSourcesByDownloads：降序、无计数垫底、同分按原序', () {
    final List<MangaOnlineSourceRow> sorted = sortMangaSourcesByDownloads(
      <MangaOnlineSourceRow>[
        _source('low', '1', 0),
        _source('none', '2', 1),
        _source('high', '3', 2),
        _source('high', '4', 3),
        _source('mid', '5', 4),
      ],
      <String, int>{'low': 5, 'high': 500, 'mid': 50},
    );
    expect(
      sorted.map((MangaOnlineSourceRow row) => row.sourceId).toList(),
      <String>['3', '4', '5', '1', '2'],
    );
  });
}
