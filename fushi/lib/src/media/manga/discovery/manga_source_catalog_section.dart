/// 漫画发现页的「可浏览来源」一节 + 它的数据快照。
///
/// 这一节是此前独立存在的「浏览」视图（`manga_browse_page.dart`）的全部内容：
/// 内置 mokuro.moe 目录 + 已启用 Aidoku 包 + 已启用 Mihon 在线源，各自一张卡片、
/// 点进各自的浏览页。两个 tab 的文案被改成同一个「发现」之后
/// （`library_view_discover` 与 `library_view_browse` 在漫画库同时挂着），用户点
/// 哪个都分不清；能力合进发现页，冗余 tab 删掉（BUG-1710）。
///
/// 快照 [MangaSourceCatalog] 是页面与本节之间**唯一**的数据契约：页面负责按平台
/// 发现来源（或在测试里直接注入），本节只负责渲染。这样 widget 测试不用架起真实
/// 扩展宿主，也不用碰 `AppModel`。
///
/// 平台差异只体现在**内容**上，不体现在结构上：Mihon 仅桌面/安卓有宿主，Aidoku
/// 只在 macOS / iOS 有宿主，Linux 两者皆无时这一节仍在原位，只列内置来源。
library;

import 'package:flutter/material.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_display_name.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';
import 'package:fushi/utils.dart';

/// 发现页当前认识的「可浏览来源」快照（三类来源的**已启用**子集）。
///
/// id 口径与 `manga_discovery_source_feeds.dart` 的 feed id 一致，来源热门行因此
/// 可以直接按 id 与下拉选中项对齐，不需要第二张映射表。
@immutable
class MangaSourceCatalog {
  const MangaSourceCatalog({
    this.mokuroEnabled = false,
    this.aidokuPackages = const <AidokuInstalledPackage>[],
    this.mihonSources = const <MangaOnlineSourceRow>[],
    this.opdsServers = const <OpdsServerConfig>[],
    this.aidokuError,
  });

  /// 内置 mokuro.moe 目录的来源 id。
  static const String mokuroSourceId = 'mokuro';

  /// Aidoku 已装包的来源 id。
  static String aidokuSourceId(AidokuInstalledPackage package) =>
      'aidoku:${package.id}';

  /// Mihon 在线源的来源 id（与 `mihonDiscoverySourceFeeds` 生成的 feed id 同式）。
  static String mihonSourceId(MangaOnlineSourceRow source) =>
      'mihon:${source.extensionPackage}:${source.sourceId}';

  /// 内置 mokuro.moe 目录是否参与浏览（「来源」视图里的开关）。
  final bool mokuroEnabled;

  /// 已启用的 Aidoku 已装包。
  final List<AidokuInstalledPackage> aidokuPackages;

  /// 已启用、且提供它的扩展也启用的 Mihon 在线源。
  final List<MangaOnlineSourceRow> mihonSources;

  /// 已启用的、用户自配的 OPDS 书目服务器（供漫画的那一面）。
  ///
  /// 与前三类的差别：OPDS **没有「热门 feed」的概念**——它的根就是一棵可浏览的
  /// 目录树。所以它只出现在「浏览来源」卡片里，**不进** [sourceOptions]：
  /// 进了下拉就意味着选中它以后正文该显示一行热门，而那一行恒空
  /// （mokuro 已有先例：它同样不在聚合搜索的源模型里，选中即直接开目录页）。
  final List<OpdsServerConfig> opdsServers;

  /// Aidoku 包清单读取失败时的错误（渲染成一行提示，不吞）。
  final Object? aidokuError;

  bool get isEmpty =>
      !mokuroEnabled &&
      aidokuPackages.isEmpty &&
      mihonSources.isEmpty &&
      opdsServers.isEmpty;

  /// 下拉选项（按 mokuro -> Aidoku -> Mihon 的展示顺序，与卡片顺序一致）。
  List<DiscoverySourceOption> get sourceOptions => <DiscoverySourceOption>[
        if (mokuroEnabled)
          DiscoverySourceOption(
            id: mokuroSourceId,
            label: t.mihon_source_browse_mokuro,
          ),
        for (final AidokuInstalledPackage package in aidokuPackages)
          DiscoverySourceOption(
            id: aidokuSourceId(package),
            label: package.name,
          ),
        for (final MangaOnlineSourceRow source in mihonSources)
          DiscoverySourceOption(
            id: mihonSourceId(source),
            label: mangaSourceDisplayName(
              name: source.name,
              language: source.language,
            ),
          ),
      ];

  /// 收窄到单个来源。[kDiscoveryAllSourcesId] 原样返回（「全部来源」不过滤）。
  ///
  /// 选中具体来源后，正文、聚合搜索的源集合、「浏览来源」卡片全部由这一个方法
  /// 收窄——三处各写一遍过滤条件正是口径漂移的来源。
  MangaSourceCatalog filterById(String sourceId) {
    if (sourceId == kDiscoveryAllSourcesId) return this;
    return MangaSourceCatalog(
      mokuroEnabled: mokuroEnabled && sourceId == mokuroSourceId,
      aidokuPackages: aidokuPackages
          .where((AidokuInstalledPackage package) =>
              aidokuSourceId(package) == sourceId)
          .toList(growable: false),
      mihonSources: mihonSources
          .where((MangaOnlineSourceRow source) =>
              mihonSourceId(source) == sourceId)
          .toList(growable: false),
      // OPDS 不在 [sourceOptions] 里，所以 [sourceId] 永远不会是某台 OPDS 服务器；
      // 用户选中了具体来源就意味着「只看这一个」，OPDS 卡片必须一并让位，
      // 否则收窄后的列表里会留着一堆与选择无关的卡片。
      opdsServers: const <OpdsServerConfig>[],
      aidokuError: aidokuError,
    );
  }
}

/// 发现页顶部的「浏览来源」快捷条：每个已启用来源一枚紧凑磁贴，横向排开，
/// 点进各自的目录。
///
/// 此前这一节是页底一列整宽大卡片：启用二十几个源时要滚过全部热门行才看得到，
/// 而它恰恰是「去某个源里逛」的最短路径。改成页首横滑条后，来源多少都只占一行
/// 高度；热门行在它下面照常展开。
///
/// 空态（一个来源都没有）不在这里渲染：页面会整页换成引导空态，这一节此时根本
/// 不挂载——两处都写空态提示就会叠出两句同义文案。
class MangaSourceCatalogSection extends StatelessWidget {
  const MangaSourceCatalogSection({
    required this.catalog,
    required this.onOpenMokuro,
    required this.onOpenAidoku,
    required this.onOpenMihon,
    required this.onOpenOpds,
    super.key,
  });

  final MangaSourceCatalog catalog;
  final VoidCallback onOpenMokuro;
  final ValueChanged<AidokuInstalledPackage> onOpenAidoku;
  final ValueChanged<MangaOnlineSourceRow> onOpenMihon;
  final ValueChanged<OpdsServerConfig> onOpenOpds;

  /// 磁贴条高度：两行文字 + 上下内边距，全部磁贴同高。
  static const double stripHeight = 64;

  @override
  Widget build(BuildContext context) {
    final Object? error = catalog.aidokuError;
    final List<Widget> tiles = <Widget>[
      if (catalog.mokuroEnabled)
        _SourceTile(
          key: const ValueKey<String>('manga-source-mokuro'),
          leading: const Icon(Icons.auto_stories_outlined),
          title: t.mihon_source_browse_mokuro,
          subtitle: 'mokuro.moe',
          onTap: onOpenMokuro,
        ),
      for (final AidokuInstalledPackage package in catalog.aidokuPackages)
        _SourceTile(
          key: ValueKey<String>('manga-aidoku-${package.id}'),
          leading: _LanguageBadge(
            package.languages.isEmpty ? '' : package.languages.first,
          ),
          title: package.name,
          subtitle: package.id,
          onTap: () => onOpenAidoku(package),
        ),
      for (final MangaOnlineSourceRow source in catalog.mihonSources)
        _SourceTile(
          key: ValueKey<String>(
            'manga-mihon-${MangaSourceCatalog.mihonSourceId(source)}',
          ),
          leading: _LanguageBadge(source.language),
          title: source.name,
          subtitle: source.baseUrl.isEmpty
              ? source.extensionPackage
              : Uri.tryParse(source.baseUrl)?.host ?? source.baseUrl,
          pinned: source.pinned,
          onTap: () => onOpenMihon(source),
        ),
      for (final OpdsServerConfig server in catalog.opdsServers)
        _SourceTile(
          key: ValueKey<String>('manga-opds-${server.id}'),
          leading: const Icon(Icons.menu_book_outlined),
          title: server.displayName,
          subtitle: server.catalogUrl.host,
          onTap: () => onOpenOpds(server),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              t.manga_discovery_sources_browse,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 8),
          if (tiles.isNotEmpty)
            // 桌面端默认 dragDevices 不含 mouse，横滑条必须包
            // HorizontalDragScrollable（横向滚动守卫）。
            SizedBox(
              height: stripHeight,
              child: HorizontalDragScrollable(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: tiles.length,
                  separatorBuilder: (BuildContext context, int index) =>
                      const SizedBox(width: 8),
                  itemBuilder: (BuildContext context, int index) =>
                      tiles[index],
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '$error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// 一枚来源磁贴：图标/语言徽标 + 名称 + 一行副标题（域名或包名）。
class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.pinned = false,
    super.key,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: 216,
      child: FushiCard(
        padding: EdgeInsets.zero,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: <Widget>[
              SizedBox.square(dimension: 36, child: Center(child: leading)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                pinned ? Icons.push_pin_outlined : Icons.chevron_right,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 语言码徽标（`JA` / `ZH` …）；空码显示 `?`。
class _LanguageBadge extends StatelessWidget {
  const _LanguageBadge(this.language);

  final String language;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: FushiBorderRadius.control,
      ),
      child: Text(
        language.isEmpty ? '?' : language.toUpperCase(),
        maxLines: 1,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
