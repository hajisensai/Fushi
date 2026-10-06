/// 漫画发现页的「可浏览来源」一节 + 它的数据快照。
///
/// 这一节是此前独立存在的「浏览」视图（`manga_browse_page.dart`）的全部内容：
/// 内置 mokuro.moe 目录 + 已启用 Mihon 在线源 + OPDS 服务器，各自一张卡片、
/// 点进各自的浏览页。两个 tab 的文案被改成同一个「发现」之后
/// （`library_view_discover` 与 `library_view_browse` 在漫画库同时挂着），用户点
/// 哪个都分不清；能力合进发现页，冗余 tab 删掉（BUG-1710）。
///
/// 快照 [MangaSourceCatalog] 是页面与本节之间**唯一**的数据契约：页面负责按平台
/// 发现来源（或在测试里直接注入），本节只负责渲染。这样 widget 测试不用架起真实
/// 扩展宿主，也不用碰 `AppModel`。
///
/// 平台差异只体现在**内容**上，不体现在结构上：Mihon 仅桌面/安卓有宿主，没有
/// 宿主的平台（iOS）这一节仍在原位，只列内置来源。
library;

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_horizontal_edge_fade.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
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
    this.mihonSources = const <MangaOnlineSourceRow>[],
    this.opdsServers = const <OpdsServerConfig>[],
  });

  /// 内置 mokuro.moe 目录的来源 id。
  static const String mokuroSourceId = 'mokuro';

  /// Mihon 在线源的来源 id（与 `mihonDiscoverySourceFeeds` 生成的 feed id 同式）。
  static String mihonSourceId(MangaOnlineSourceRow source) =>
      'mihon:${source.extensionPackage}:${source.sourceId}';

  /// 内置 mokuro.moe 目录是否参与浏览（「来源」视图里的开关）。
  final bool mokuroEnabled;

  /// 已启用、且提供它的扩展也启用的 Mihon 在线源。
  final List<MangaOnlineSourceRow> mihonSources;

  /// 已启用的、用户自配的 OPDS 书目服务器（供漫画的那一面）。
  ///
  /// 与前三类的差别：OPDS **没有「热门 feed」的概念**——它的根就是一棵可浏览的
  /// 目录树。所以它只出现在「浏览来源」卡片里，**不进** [sourceOptions]：
  /// 进了下拉就意味着选中它以后正文该显示一行热门，而那一行恒空
  /// （mokuro 已有先例：它同样不在聚合搜索的源模型里，选中即直接开目录页）。
  final List<OpdsServerConfig> opdsServers;

  bool get isEmpty =>
      !mokuroEnabled && mihonSources.isEmpty && opdsServers.isEmpty;

  /// 下拉选项（按 mokuro -> Mihon 的展示顺序，与卡片顺序一致）。
  List<DiscoverySourceOption> get sourceOptions => <DiscoverySourceOption>[
        if (mokuroEnabled)
          DiscoverySourceOption(
            id: mokuroSourceId,
            label: t.mihon_source_browse_mokuro,
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
      mihonSources: mihonSources
          .where((MangaOnlineSourceRow source) =>
              mihonSourceId(source) == sourceId)
          .toList(growable: false),
      // OPDS 不在 [sourceOptions] 里，所以 [sourceId] 永远不会是某台 OPDS 服务器；
      // 用户选中了具体来源就意味着「只看这一个」，OPDS 卡片必须一并让位，
      // 否则收窄后的列表里会留着一堆与选择无关的卡片。
      opdsServers: const <OpdsServerConfig>[],
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
    required this.onOpenMihon,
    required this.onOpenOpds,
    super.key,
  });

  final MangaSourceCatalog catalog;
  final VoidCallback onOpenMokuro;
  final ValueChanged<MangaOnlineSourceRow> onOpenMihon;
  final ValueChanged<OpdsServerConfig> onOpenOpds;

  /// 磁贴条高度：两行文字 + 上下内边距，全部磁贴同高。
  static const double stripHeight = 64;

  @override
  Widget build(BuildContext context) {
    final List<Widget> tiles = <Widget>[
      if (catalog.mokuroEnabled)
        _SourceTile(
          key: const ValueKey<String>('manga-source-mokuro'),
          leading: const FushiListLeadingIcon(
            FushiIcons.books,
            shape: FushiLeadingShape.cookie,
            tone: FushiCardTone.primary,
            size: 36,
            iconSize: 20,
          ),
          title: t.mihon_source_browse_mokuro,
          subtitle: 'mokuro.moe',
          onTap: onOpenMokuro,
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
          leading: const FushiListLeadingIcon(
            FushiIcons.books,
            shape: FushiLeadingShape.cookie,
            tone: FushiCardTone.primary,
            size: 36,
            iconSize: 20,
          ),
          title: server.displayName,
          subtitle: server.catalogUrl.host,
          onTap: () => onOpenOpds(server),
        ),
    ];
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 区块标题与下方热门横滑行同一套 [FushiSectionTitle]（MD3 titleLarge /
          // Apple Title 2 粗体），不再是小一号的 titleMedium。
          // 本区块是发现页正文的首个分区：上方只隔工具区底边的 gap，合计 16
          // （与视频发现页工具区到首屏内容同一间距），不再叠一个 section 大边距。
          FushiSectionTitle(
            t.manga_discovery_sources_browse,
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
          ),
          if (tiles.isNotEmpty)
            // 桌面端默认 dragDevices 不含 mouse，横滑条必须包
            // HorizontalDragScrollable（横向滚动守卫）。
            SizedBox(
              height: stripHeight,
              child: FushiHorizontalEdgeFade(
                child: HorizontalDragScrollable(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    // 与区块标题、下方横滑行同一页边距，左缘对齐。
                    padding: EdgeInsets.symmetric(
                      horizontal: tokens.spacing.page,
                    ),
                    itemCount: tiles.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        SizedBox(width: tokens.spacing.gap),
                    itemBuilder: (BuildContext context, int index) =>
                        tiles[index],
                  ),
                ),
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 次级文字 / 行尾图标：Apple 取 secondaryLabel / tertiaryLabel 灰阶，MD3
    // onSurfaceVariant（与共享列表行同口径）。
    final bool apple = isGlassDesign(context);
    final Color secondary = apple
        ? appleColorsOf(context).secondaryLabel
        : tokens.surfaces.onVariant;
    final Color chevron = apple
        ? appleColorsOf(context).tertiaryLabel
        : tokens.surfaces.onVariant;
    // 实色内容卡（MD3 surfaceContainerLow / Apple secondarySystemGrouped），
    // 不是玻璃；焦点 / Enter 由 FushiCard 提供。
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
                      style: tokens.type.listTitle,
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.type.metadata.copyWith(color: secondary),
                    ),
                  ],
                ),
              ),
              FushiIcon(
                pinned ? FushiIcons.pin : FushiIcons.chevronRight,
                size: 18,
                color: chevron,
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
    // 中性底徽标（不再是 secondaryContainer 彩块），文字次级标签色。
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: fushiNeutralBlockDecoration(context),
      child: Text(
        language.isEmpty ? '?' : language.toUpperCase(),
        maxLines: 1,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: fushiNeutralSecondaryForeground(context),
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
