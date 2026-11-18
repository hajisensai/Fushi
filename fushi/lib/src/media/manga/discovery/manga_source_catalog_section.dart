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

import 'package:material_ui/material_ui.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_display_name.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_source_block.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';

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

  /// 全部来源的展示顺序：**置顶在前**，其余按现有顺序（mokuro → Mihon 的
  /// `sortOrder` → OPDS）。稳定排序；没有「最近使用」排序（所有者拍板 DI17：
  /// [MangaOnlineSourceRow] 没有这个字段，不为它新增持久化）。
  List<MangaCatalogSourceEntry> get entries {
    final List<MangaCatalogSourceEntry> all = <MangaCatalogSourceEntry>[
      if (mokuroEnabled)
        MangaCatalogSourceEntry(
          id: mokuroSourceId,
          name: t.mihon_source_browse_mokuro,
          chips: <String>['mokuro.moe', t.discovery_source_chip_preset],
          pinned: false,
          kind: MangaCatalogSourceKind.mokuro,
        ),
      for (final MangaOnlineSourceRow source in mihonSources)
        MangaCatalogSourceEntry(
          id: mihonSourceId(source),
          name: source.name,
          chips: <String>[
            mangaSourceLanguageLabel(source.language),
            if (source.pinned) t.discovery_source_chip_pinned,
          ],
          pinned: source.pinned,
          kind: MangaCatalogSourceKind.mihon,
          mihon: source,
        ),
      for (final OpdsServerConfig server in opdsServers)
        MangaCatalogSourceEntry(
          id: 'opds:${server.id}',
          name: server.displayName,
          chips: <String>['OPDS', t.discovery_source_chip_user_added],
          pinned: false,
          kind: MangaCatalogSourceKind.opds,
          opds: server,
        ),
    ];
    return <MangaCatalogSourceEntry>[
      for (final MangaCatalogSourceEntry e in all)
        if (e.pinned) e,
      for (final MangaCatalogSourceEntry e in all)
        if (!e.pinned) e,
    ];
  }

  /// 漫画首块右侧的两个来源（设计稿第 3 节）：有置顶源就放前 2 个置顶源；没有
  /// 就放前 2 个启用源（现有顺序）。这里出现的源不在下方网格重复——调用方把
  /// 返回值传给 [MangaSourceCatalogSection.excludeIds]。
  List<String> get heroSideIds {
    final List<MangaCatalogSourceEntry> ordered = entries;
    final List<MangaCatalogSourceEntry> pinned = <MangaCatalogSourceEntry>[
      for (final MangaCatalogSourceEntry e in ordered)
        if (e.pinned) e,
    ];
    return (pinned.isNotEmpty ? pinned : ordered)
        .take(2)
        .map((MangaCatalogSourceEntry e) => e.id)
        .toList(growable: false);
  }

  /// 收窄到单个来源。[kDiscoveryAllSourcesId] 原样返回（「全部来源」不过滤）。
  ///
  /// 选中具体来源后，正文、聚合搜索的源集合、「浏览来源」卡片全部由这一个方法
  /// 收窄——三处各写一遍过滤条件正是口径漂移的来源。
  MangaSourceCatalog filterById(String sourceId) {
    if (sourceId == kDiscoveryAllSourcesId) return this;
    return MangaSourceCatalog(
      mokuroEnabled: mokuroEnabled && sourceId == mokuroSourceId,
      mihonSources: mihonSources
          .where(
            (MangaOnlineSourceRow source) => mihonSourceId(source) == sourceId,
          )
          .toList(growable: false),
      // OPDS 不在 [sourceOptions] 里，所以 [sourceId] 永远不会是某台 OPDS 服务器；
      // 用户选中了具体来源就意味着「只看这一个」，OPDS 卡片必须一并让位，
      // 否则收窄后的列表里会留着一堆与选择无关的卡片。
      opdsServers: const <OpdsServerConfig>[],
    );
  }
}

/// 来源块的三类来源。
enum MangaCatalogSourceKind { mokuro, mihon, opds }

/// [MangaSourceCatalog.entries] 的一项：渲染来源块所需的全部信息。
@immutable
class MangaCatalogSourceEntry {
  const MangaCatalogSourceEntry({
    required this.id,
    required this.name,
    required this.chips,
    required this.pinned,
    required this.kind,
    this.mihon,
    this.opds,
  });

  /// 来源 id（mokuro / Mihon 与热门 feed id 同式；OPDS 是 `opds:<服务器 id>`）。
  final String id;
  final String name;

  /// 块内 chip：语言 / 置顶 / 预置 / 用户添加。
  final List<String> chips;
  final bool pinned;
  final MangaCatalogSourceKind kind;
  final MangaOnlineSourceRow? mihon;
  final OpdsServerConfig? opds;

  /// 块的稳定 key（沿用旧磁贴的 key，测试与焦点导航按它找）。
  String get widgetKey => switch (kind) {
    MangaCatalogSourceKind.mokuro => 'manga-source-mokuro',
    MangaCatalogSourceKind.mihon => 'manga-mihon-$id',
    MangaCatalogSourceKind.opds => 'manga-opds-${opds!.id}',
  };
}

/// 语言码 → 块内语言 chip：`all` / `multi` 显示「多语言」，空码显示「?」，
/// 其余大写码（`EN` / `JA`）。
String mangaSourceLanguageLabel(String language) {
  final String code = language.trim().toLowerCase();
  if (code.isEmpty) return '?';
  if (code == 'all' || code == 'multi' || code == 'other') {
    return t.discovery_source_language_multi;
  }
  return code.toUpperCase();
}

/// 渲染一个来源块的共享参数（网格与首块旁两块同一份）。
class _CatalogBlockContext {
  const _CatalogBlockContext({
    required this.onOpenMokuro,
    required this.onOpenMihon,
    required this.onOpenOpds,
    required this.coverPreviews,
    required this.failures,
    required this.onRetry,
  });

  final VoidCallback onOpenMokuro;
  final ValueChanged<MangaOnlineSourceRow> onOpenMihon;
  final ValueChanged<OpdsServerConfig> onOpenOpds;
  final Map<String, List<Widget>> coverPreviews;
  final Set<String> failures;
  final VoidCallback? onRetry;

  Widget block(MangaCatalogSourceEntry entry, {double? height}) {
    final VoidCallback onTap = switch (entry.kind) {
      MangaCatalogSourceKind.mokuro => onOpenMokuro,
      MangaCatalogSourceKind.mihon => () => onOpenMihon(entry.mihon!),
      MangaCatalogSourceKind.opds => () => onOpenOpds(entry.opds!),
    };
    return DiscoverySourceBlock(
      key: ValueKey<String>(entry.widgetKey),
      sourceId: entry.id,
      name: entry.name,
      chips: entry.chips,
      covers: coverPreviews[entry.id] ?? const <Widget>[],
      failed: failures.contains(entry.id),
      onRetry: onRetry,
      onTap: onTap,
      height: height,
    );
  }
}

/// 漫画发现页的「浏览来源」一节：来源色块网格（拼贴改版 DI2）。
///
/// 每个已启用来源一块按源取色的色块（`DiscoverySourceBlock`）：多边形 glyph +
/// 名称 + 语言 / 置顶 chip，漫画源带 3–4 张热门封面小条（[coverPreviews]，由
/// 页面把各源热门行已拿到的封面交进来，本节不为它多发请求）；加载失败的源
/// （[failures]）块内出「无法连接 · 重试」。置顶在前，其余按现有顺序；漫画首块
/// 右侧已经显示的源（[excludeIds]，见 [MangaSourceCatalog.heroSideIds]）不在这里
/// 重复。末尾「添加来源」块（[onAddSource]）只做跳转。
///
/// 空态（一个来源都没有）不在这里渲染：页面会整页换成引导空态，这一节此时根本
/// 不挂载——两处都写空态提示就会叠出两句同义文案。
class MangaSourceCatalogSection extends StatelessWidget {
  const MangaSourceCatalogSection({
    required this.catalog,
    required this.onOpenMokuro,
    required this.onOpenMihon,
    required this.onOpenOpds,
    this.excludeIds = const <String>{},
    this.coverPreviews = const <String, List<Widget>>{},
    this.failures = const <String>{},
    this.onRetry,
    this.onAddSource,
    super.key,
  });

  final MangaSourceCatalog catalog;
  final VoidCallback onOpenMokuro;
  final ValueChanged<MangaOnlineSourceRow> onOpenMihon;
  final ValueChanged<OpdsServerConfig> onOpenOpds;

  /// 不在网格里重复的来源 id（已在漫画首块右侧显示的）。
  final Set<String> excludeIds;

  /// 来源 id → 封面条（该源热门行已拿到的前几张封面 widget）。
  final Map<String, List<Widget>> coverPreviews;

  /// 最近一次加载失败的来源 id。
  final Set<String> failures;

  /// 失败块的「重试」。
  final VoidCallback? onRetry;

  /// 「添加来源」块的去处；null = 不渲染该块（没有去处时不放点了没反应的块）。
  final VoidCallback? onAddSource;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<MangaCatalogSourceEntry> all = catalog.entries;
    final List<MangaCatalogSourceEntry> shown = <MangaCatalogSourceEntry>[
      for (final MangaCatalogSourceEntry e in all)
        if (!excludeIds.contains(e.id)) e,
    ];
    final int excluded = all.length - shown.length;
    final _CatalogBlockContext blocks = _CatalogBlockContext(
      onOpenMokuro: onOpenMokuro,
      onOpenMihon: onOpenMihon,
      onOpenOpds: onOpenOpds,
      coverPreviews: coverPreviews,
      failures: failures,
      onRetry: onRetry,
    );
    final VoidCallback? add = onAddSource;
    final String caption = <String>[
      t.discovery_sources_order_caption,
      if (excluded > 0) t.discovery_sources_excluded_caption(n: excluded),
      t.discovery_sources_all_count(n: all.length),
    ].join(' · ');
    return FushiEntranceScope(
      replayKey: shown.map((MangaCatalogSourceEntry e) => e.id).join('|'),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiSectionTitle(
              t.manga_discovery_sources_browse,
              shrinkTrailing: true,
              trailing: Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.metadata.copyWith(
                  color: tokens.surfaces.onVariant,
                ),
              ),
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.gap,
                tokens.spacing.page,
                tokens.spacing.gap,
              ),
            ),
            if (shown.isNotEmpty || add != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
                child: DiscoverySourceBlockGrid(
                  children: <Widget>[
                    for (final MangaCatalogSourceEntry entry in shown)
                      blocks.block(entry),
                    if (add != null)
                      DiscoveryAddSourceBlock(
                        key: const ValueKey<String>('manga-source-add'),
                        onTap: add,
                        hint: mangaAddSourceHint(),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 「添加来源」块的副文案：有在线漫画源宿主能力时去「扩展」装，否则（iOS 合规）
/// 连接自己的服务器。判据只走 [StoreRestrictedCapability]。
String mangaAddSourceHint() =>
    StoreRestrictedCapability.onlineMangaSource.isAvailable
    ? t.discovery_source_add_hint_extensions
    : t.discovery_source_add_hint_server;

/// 漫画首块右侧的两块来源（[MangaSourceCatalog.heroSideIds]）：竖排、平分父级给
/// 的高度（与首块同高）。没有来源时不占位。
class MangaSourceHeroSide extends StatelessWidget {
  const MangaSourceHeroSide({
    required this.catalog,
    required this.onOpenMokuro,
    required this.onOpenMihon,
    required this.onOpenOpds,
    this.coverPreviews = const <String, List<Widget>>{},
    this.failures = const <String>{},
    this.onRetry,
    super.key,
  });

  final MangaSourceCatalog catalog;
  final VoidCallback onOpenMokuro;
  final ValueChanged<MangaOnlineSourceRow> onOpenMihon;
  final ValueChanged<OpdsServerConfig> onOpenOpds;
  final Map<String, List<Widget>> coverPreviews;
  final Set<String> failures;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    final List<String> ids = catalog.heroSideIds;
    final List<MangaCatalogSourceEntry> side = <MangaCatalogSourceEntry>[
      for (final MangaCatalogSourceEntry e in catalog.entries)
        if (ids.contains(e.id)) e,
    ];
    if (side.isEmpty) return const SizedBox.shrink();
    final _CatalogBlockContext blocks = _CatalogBlockContext(
      onOpenMokuro: onOpenMokuro,
      onOpenMihon: onOpenMihon,
      onOpenOpds: onOpenOpds,
      coverPreviews: coverPreviews,
      failures: failures,
      onRetry: onRetry,
    );
    return Column(
      key: const ValueKey<String>('manga-source-hero-side'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < side.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: gap),
          Expanded(
            child: FushiStaggeredEntrance(
              index: i + 1,
              child: blocks.block(side[i]),
            ),
          ),
        ],
      ],
    );
  }
}
