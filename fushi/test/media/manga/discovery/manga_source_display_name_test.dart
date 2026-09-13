/// 同一个 Mihon 扩展按语言拆出的同名来源，在发现页下拉与热门行标题里必须带
/// 语言码——否则 keiyoushi 一个 MyReadingManga 装出十几条一模一样的
/// 「MyReadingManga」，用户根本分不清选的是哪一条。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_source_feeds.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_catalog_section.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_display_name.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';

MangaOnlineSourceRow _row(String sourceId, String language) =>
    MangaOnlineSourceRow(
      extensionPackage: 'eu.kanade.tachiyomi.extension.all.myreadingmanga',
      sourceId: sourceId,
      name: 'MyReadingManga',
      language: language,
      baseUrl: 'https://myreadingmanga.info',
      enabled: true,
      pinned: false,
      sortOrder: 0,
    );

void main() {
  test('mangaSourceDisplayName：带语言码大写；语言空/空白退回裸名', () {
    expect(
      mangaSourceDisplayName(name: 'MyReadingManga', language: 'en'),
      'MyReadingManga (EN)',
    );
    expect(
      mangaSourceDisplayName(name: 'MyReadingManga', language: ' zh-Hans '),
      'MyReadingManga (ZH-HANS)',
    );
    expect(mangaSourceDisplayName(name: 'Comix', language: ''), 'Comix');
    expect(mangaSourceDisplayName(name: 'Comix', language: '  '), 'Comix');
  });

  test('sourceOptions：同名多语言 Mihon 源的下拉标签互不相同', () {
    final MangaSourceCatalog catalog = MangaSourceCatalog(
      mihonSources: <MangaOnlineSourceRow>[
        _row('1', 'en'),
        _row('2', 'ja'),
        _row('3', 'zh'),
      ],
    );
    final List<String> labels = catalog.sourceOptions
        .map((DiscoverySourceOption o) => o.label)
        .toList(growable: false);
    expect(labels, <String>[
      'MyReadingManga (EN)',
      'MyReadingManga (JA)',
      'MyReadingManga (ZH)',
    ]);
    expect(labels.toSet().length, labels.length, reason: '标签必须两两可区分');
  });

  test('MangaDiscoverySourceFeed.displayName 与下拉标签同一口径', () {
    final MangaDiscoverySourceFeed feed = MangaDiscoverySourceFeed(
      id: 'mihon:pkg:1',
      name: 'MyReadingManga',
      language: 'ko',
      loadPopular: () async => const <MangaDiscoverySourceItem>[],
    );
    expect(feed.displayName, 'MyReadingManga (KO)');
  });
}
