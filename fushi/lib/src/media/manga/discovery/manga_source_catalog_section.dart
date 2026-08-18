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
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
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

  /// Aidoku 包清单读取失败时的错误（渲染成一行提示，不吞）。
  final Object? aidokuError;

  bool get isEmpty =>
      !mokuroEnabled && aidokuPackages.isEmpty && mihonSources.isEmpty;

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
            label: source.name,
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
      aidokuError: aidokuError,
    );
  }
}

/// 发现页正文末尾的「浏览来源」一节：每个已启用来源一张卡片，点进各自的目录。
class MangaSourceCatalogSection extends StatelessWidget {
  const MangaSourceCatalogSection({
    required this.catalog,
    required this.onOpenMokuro,
    required this.onOpenAidoku,
    required this.onOpenMihon,
    super.key,
  });

  final MangaSourceCatalog catalog;
  final VoidCallback onOpenMokuro;
  final ValueChanged<AidokuInstalledPackage> onOpenAidoku;
  final ValueChanged<MangaOnlineSourceRow> onOpenMihon;

  @override
  Widget build(BuildContext context) {
    final Object? error = catalog.aidokuError;
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (catalog.mokuroEnabled)
                  FushiCard(
                    padding: EdgeInsets.zero,
                    child: FushiListItem(
                      leading: const Icon(Icons.auto_stories_outlined),
                      title: Text(t.mihon_source_browse_mokuro),
                      subtitle: const Text('mokuro.moe'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: onOpenMokuro,
                    ),
                  ),
                for (final AidokuInstalledPackage package
                    in catalog.aidokuPackages)
                  FushiCard(
                    padding: EdgeInsets.zero,
                    child: FushiListItem(
                      leading: CircleAvatar(
                        child: Text(
                          package.languages.isEmpty
                              ? '?'
                              : package.languages.first.toUpperCase(),
                        ),
                      ),
                      title: Text(package.name),
                      subtitle: Text(package.id),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => onOpenAidoku(package),
                    ),
                  ),
                for (final MangaOnlineSourceRow source in catalog.mihonSources)
                  FushiCard(
                    padding: EdgeInsets.zero,
                    child: FushiListItem(
                      leading: CircleAvatar(
                        child: Text(
                          source.language.isEmpty
                              ? '?'
                              : source.language.toUpperCase(),
                        ),
                      ),
                      title: Text(source.name),
                      subtitle: Text(
                        source.baseUrl.isEmpty
                            ? source.extensionPackage
                            : source.baseUrl,
                      ),
                      trailing: source.pinned
                          ? const Icon(Icons.push_pin_outlined)
                          : const Icon(Icons.chevron_right),
                      onTap: () => onOpenMihon(source),
                    ),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 16,
                    ),
                    child: Text(
                      '$error',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                // 有扩展宿主却一个来源都没启用时才提示「先装一个扩展」；没有宿主
                // 的平台（Linux 等）提示这句只会误导，那里本来就装不了扩展。
                if (MihonRuntimeFactory.isSupported && catalog.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 32,
                    ),
                    child: Text(
                      t.mihon_source_empty,
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
