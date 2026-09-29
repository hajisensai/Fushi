/// 发现页「来源热门行」的数据口 + Mihon 适配（P2，用户决策混合 C 的下半部）。
///
/// 页面只认「名字 + 一个加载函数 + 一组可渲染条目 + 可选的目录入口」，Mihon 的 context/封面/详情页跳转全部收在适配函数里——
/// 页面因此可以用假 feed 做 widget 测试，不用架起真实扩展宿主。
library;

import 'package:flutter/widgets.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_display_name.dart';
import 'package:fushi/src/media/manga/mihon/mihon_enabled_sources.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/utils.dart';

/// 一条可渲染的来源条目：标题 + 封面构建器 + 打开动作。
class MangaDiscoverySourceItem {
  const MangaDiscoverySourceItem({
    required this.title,
    required this.buildCover,
    required this.open,
  });

  final String title;
  final Widget Function(BuildContext context) buildCover;
  final void Function(BuildContext context) open;
}

/// 来源热门的一页：条目 + 是否还有下一页。
class MangaDiscoverySourcePage {
  const MangaDiscoverySourcePage({required this.items, required this.hasMore});

  final List<MangaDiscoverySourceItem> items;
  final bool hasMore;
}

/// 一条来源热门行：空行由页面收起，失败汇总进页首的来源失败横幅。
class MangaDiscoverySourceFeed {
  const MangaDiscoverySourceFeed({
    required this.id,
    required this.name,
    required this.language,
    required this.loadPopular,
    this.loadPopularPage,
    this.openCatalog,
  });

  final String id;
  final String name;
  final String language;

  /// 热门第 1 页（横滑行只要这一页）。
  final Future<List<MangaDiscoverySourceItem>> Function() loadPopular;

  /// 按页取热门（页码从 1 起）；给定时单源网格滚到底自动翻页，为空时网格只有
  /// [loadPopular] 那一页。
  final Future<MangaDiscoverySourcePage> Function(int page)? loadPopularPage;

  /// 打开该来源的完整目录（行头「查看全部」）；为空时不出这个按钮。
  final void Function(BuildContext context)? openCatalog;

  /// 行标题用的展示名（带语言码；同名多语言源只有这样才分得开）。
  String get displayName =>
      mangaSourceDisplayName(name: name, language: language);
}

/// 把全部已启用 Mihon 在线来源适配成热门行。每行首次可见才真正 getPopular
/// 第 1 页（单源网格再按 `hasNextPage` 往后翻）；封面走 [MihonSourceImage]（带扩展拦截器/cookie），共享 [imageQueue]
/// 限并发。
List<MangaDiscoverySourceFeed> mihonDiscoverySourceFeeds({
  required MihonManager manager,
  required MihonSourceImageLoadQueue imageQueue,
}) {
  return <MangaDiscoverySourceFeed>[
    for (final MangaOnlineSourceRow row in enabledMangaOnlineSources(manager))
      MangaDiscoverySourceFeed(
        id: 'mihon:${row.extensionPackage}:${row.sourceId}',
        name: row.name,
        language: row.language,
        loadPopular: () async =>
            (await _loadMihonPopular(manager, row, imageQueue, 1)).items,
        loadPopularPage: (int page) =>
            _loadMihonPopular(manager, row, imageQueue, page),
        openCatalog: (BuildContext context) {
          Navigator.of(context).push(
            adaptivePageRoute<void>(
              context: context,
              builder: (BuildContext context) => MihonSourceBrowsePage(
                manager: manager,
                target: MihonInstalledTarget(row),
              ),
            ),
          );
        },
      ),
  ];
}

Future<MangaDiscoverySourcePage> _loadMihonPopular(
  MihonManager manager,
  MangaOnlineSourceRow row,
  MihonSourceImageLoadQueue imageQueue,
  int pageNumber,
) async {
  final MihonSourceContext sourceContext = await manager.contextForSource(row);
  final MihonMangaPage page = await manager.runtime.getPopular(
    sourceContext.extension,
    sourceContext.source,
    page: pageNumber,
    preferences: sourceContext.preferences,
  );
  final List<MangaDiscoverySourceItem> items = <MangaDiscoverySourceItem>[
    for (final MihonManga manga in page.items)
      MangaDiscoverySourceItem(
        title: manga.title,
        buildCover: (BuildContext context) => MihonSourceImage(
          runtime: manager.runtime,
          cache: manager.coverCache,
          context: sourceContext,
          url: manga.coverUrl,
          loadQueue: imageQueue,
        ),
        open: (BuildContext context) {
          Navigator.of(context).push(
            adaptivePageRoute<void>(
              context: context,
              builder: (BuildContext context) => MihonMangaDetailPage(
                manager: manager,
                sourceContext: sourceContext,
                manga: manga,
              ),
            ),
          );
        },
      ),
  ];
  return MangaDiscoverySourcePage(items: items, hasMore: page.hasNextPage);
}
