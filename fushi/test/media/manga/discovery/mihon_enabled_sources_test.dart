import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/mihon/mihon_enabled_sources.dart';

/// 「已启用在线来源」唯一口径（浏览页/发现详情页/发现源热门行三处共用）：
/// 来源启用 且 扩展启用 才算；任一侧被关都要被滤掉；顺序保持来源表原序。
void main() {
  MangaExtensionRow extension(String packageName, {required bool enabled}) =>
      MangaExtensionRow(
        packageName: packageName,
        storeUrl: null,
        name: packageName,
        versionCode: 1,
        versionName: '1.0',
        libVersion: '1.5',
        language: 'ja',
        contentWarning: 0,
        apkPath: '$packageName.apk',
        apkSha256: 'x',
        signerSha256: 'y',
        enabled: enabled,
        installedAt: 0,
      );

  MangaOnlineSourceRow source(
    String sourceId,
    String extensionPackage, {
    required bool enabled,
  }) =>
      MangaOnlineSourceRow(
        extensionPackage: extensionPackage,
        sourceId: sourceId,
        name: sourceId,
        language: 'ja',
        baseUrl: '',
        enabled: enabled,
        pinned: false,
        sortOrder: 0,
      );

  test('来源启用且扩展启用才算；任一侧关掉都滤掉；保持原序', () {
    final List<MangaOnlineSourceRow> result = filterEnabledMangaOnlineSources(
      installed: <MangaExtensionRow>[
        extension('ext.on', enabled: true),
        extension('ext.off', enabled: false),
      ],
      sources: <MangaOnlineSourceRow>[
        source('s1', 'ext.on', enabled: true),
        source('s2', 'ext.on', enabled: false),
        source('s3', 'ext.off', enabled: true),
        source('s4', 'ext.on', enabled: true),
        source('s5', 'ext.gone', enabled: true),
      ],
    );
    expect(
      result.map((MangaOnlineSourceRow row) => row.sourceId).toList(),
      <String>['s1', 's4'],
    );
  });

  test('空输入恒为空表', () {
    expect(
      filterEnabledMangaOnlineSources(
        installed: const <MangaExtensionRow>[],
        sources: const <MangaOnlineSourceRow>[],
      ),
      isEmpty,
    );
  });
}
