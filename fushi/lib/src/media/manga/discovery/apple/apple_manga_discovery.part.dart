part of '../manga_discovery_page.dart';

/// 漫画发现「全部来源」的 Apple（Cupertino）画法（「浏览」页方案 A / 宽屏货架）。
/// 业务状态（来源清单、各源热门行、Hero 候选、失败表）全在
/// [_MangaDiscoveryPageState]，这里只换版面：
///
/// - iOS 档（窄屏）：Hero 轮播收起（拍板：按 A 收纳），「浏览来源」是一组 inset
///   grouped 来源行（中性 glyph，语言 / 置顶 / 出处降为副行，失败行副行变红 +
///   「重试」）；点行 = 只看这个源（搜索框前出来源 token，与书 / 游戏同口径），
///   OPDS 服务器不在来源筛选里，点行直接进它的目录；行下照旧是每源热门横滑；
/// - macOS 档（宽窗）：方案 B 的货架流——Hero 作首条大图货架（不再拼来源块在旁），
///   「浏览来源」是 lockup 横滑货架，再下是每源热门货架（悬停两端出箭头）。
extension _AppleMangaDiscovery on _MangaDiscoveryPageState {
  /// 点一个来源：mokuro / Mihon 只看这个源；OPDS 进目录。
  VoidCallback _appleOnSource(MangaCatalogSourceEntry entry) =>
      switch (entry.kind) {
        MangaCatalogSourceKind.opds => () => _openOpdsServer(entry.opds!),
        _ => () => _selectSource(entry.id),
      };

  String _appleCatalogCaption(MangaSourceCatalog catalog) => <String>[
    t.discovery_sources_order_caption,
    t.discovery_sources_all_count(n: catalog.entries.length),
  ].join(' · ');

  Widget _buildAppleAllSources(
    MangaSourceCatalog catalog,
    List<MangaDiscoverySourceFeed> feeds,
  ) {
    final bool mac = fushiAppleUsesMacMetrics(context);
    final double page = appleDiscoveryPageInset(context);
    final Map<String, MangaDiscoverySourceFeed> feedsById =
        <String, MangaDiscoverySourceFeed>{
          for (final MangaDiscoverySourceFeed feed in feeds) feed.id: feed,
        };
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[
      for (final MapEntry<String, Object> failure in _rowFailures.entries)
        if (feedsById.containsKey(failure.key))
          ExternalProviderFailure.fromException(
            providerId: failure.key,
            operation: 'popular',
            error: failure.value,
          ),
    ];
    final bool allFailed = feeds.isNotEmpty && failures.length == feeds.length;
    final Set<String> failedIds = <String>{
      for (final String id in _rowFailures.keys)
        if (feedsById.containsKey(id)) id,
    };
    final int generation = _generation;
    final List<_MangaHero> heroes = mac
        ? <_MangaHero>[
            for (final _MangaHero hero in _heroes)
              if (feedsById.containsKey(hero.feed.id)) hero,
          ]
        : const <_MangaHero>[];
    final Set<String> heroFeedIds = <String>{
      for (final _MangaHero hero in heroes) hero.feed.id,
    };
    final Widget? heroSlot = !mac
        ? null
        : heroes.isNotEmpty
        ? DiscoveryHeroCarousel(
            key: const ValueKey<String>('manga-discovery-hero-carousel'),
            itemCount: heroes.length,
            itemBuilder: (BuildContext context, int index) =>
                _buildHero(heroes[index], rank: index + 1),
          )
        : !_anyRowSettled && feeds.isNotEmpty
        ? const DiscoveryHeroSkeleton()
        : null;
    final VoidCallback? add = _openSourcesAction();
    final List<MangaCatalogSourceEntry> entries = catalog.entries;
    final Widget sources = mac
        ? Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: page),
                  child: AppleDiscoveryShelfHeader(
                    title: t.manga_discovery_sources_browse,
                    subtitle: _appleCatalogCaption(catalog),
                  ),
                ),
                const SizedBox(height: 8),
                AppleDiscoveryLockupStrip(
                  horizontalInset: page,
                  children: <Widget>[
                    for (int i = 0; i < entries.length; i++)
                      FushiStaggeredEntrance(
                        index: i,
                        child: AppleDiscoveryLockup(
                          key: ValueKey<String>(entries[i].widgetKey),
                          name: entries[i].name,
                          caption: appleDiscoveryCaption(entries[i].chips),
                          failed: failedIds.contains(entries[i].id),
                          actionLabel: failedIds.contains(entries[i].id)
                              ? t.retry
                              : appleDiscoveryBrowseLabel(),
                          onTap: failedIds.contains(entries[i].id)
                              ? _refresh
                              : _appleOnSource(entries[i]),
                        ),
                      ),
                    if (add != null)
                      FushiStaggeredEntrance(
                        index: entries.length,
                        child: AppleDiscoveryLockup(
                          key: const ValueKey<String>('manga-source-add'),
                          name: '${t.discovery_source_add_title}…',
                          caption: mangaAddSourceHint(),
                          actionLabel: t.manga_discovery_empty_action,
                          onTap: add,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          )
        : Padding(
            padding: EdgeInsets.fromLTRB(page, 16, page, 8),
            child: FushiStaggeredEntrance(
              index: 0,
              child: AdaptiveSettingsSection(
                title: t.manga_discovery_sources_browse,
                titleTrailing: add == null
                    ? null
                    : AppleImportSectionAction(
                        label: t.manga_discovery_empty_action,
                        onTap: add,
                      ),
                footer: AppleDiscoveryFootnote(
                  text: _appleCatalogCaption(catalog),
                ),
                children: <Widget>[
                  for (final MangaCatalogSourceEntry entry in entries)
                    AppleDiscoverySourceRow(
                      key: ValueKey<String>(entry.widgetKey),
                      name: entry.name,
                      caption: appleDiscoveryCaption(entry.chips),
                      failed: failedIds.contains(entry.id),
                      onRetry: _refresh,
                      onTap: _appleOnSource(entry),
                    ),
                  if (add != null)
                    AppleDiscoveryAddSourceRow(
                      subtitle: mangaAddSourceHint(),
                      onTap: add,
                    ),
                ],
              ),
            ),
          );
    return FushiEntranceScope(
      replayKey: entries.map((MangaCatalogSourceEntry e) => e.id).join('|'),
      child: CustomScrollView(
        key: const PageStorageKey<String>('manga-discovery-scroll'),
        slivers: <Widget>[
          const SliverToBoxAdapter(child: FushiFloatingChromeInsetSpacer()),
          if (failures.isNotEmpty && !allFailed)
            SliverToBoxAdapter(
              child: DiscoveryProviderWarningBanner(
                key: const ValueKey<String>('manga_discovery_provider_warning'),
                failures: failures,
                displayNameFor: (String id) => feedsById[id]?.displayName ?? id,
              ),
            ),
          // 槽位恒在（只换内容），理由同 M3E：下方不带 key 的 sliver 不错位重挂。
          SliverToBoxAdapter(
            key: const ValueKey<String>('manga_discovery_hero_slot'),
            child: heroSlot ?? const SizedBox.shrink(),
          ),
          SliverToBoxAdapter(child: sources),
          SliverList.list(
            key: const ValueKey<String>('manga_discovery_rows'),
            children: <Widget>[
              for (final MangaDiscoverySourceFeed feed in feeds)
                MangaDiscoverySourceRow(
                  key: ValueKey<String>(
                    'manga_discovery_source_${feed.id}#$generation',
                  ),
                  feed: feed,
                  excludeFirst: heroFeedIds.contains(feed.id),
                  onItems: (List<MangaDiscoverySourceItem> items) =>
                      _onRowItems(generation, feed, items),
                  onResult: (Object? error) =>
                      _onRowResult(generation, feed.id, error),
                ),
            ],
          ),
          if (allFailed)
            SliverToBoxAdapter(
              child: FushiPlaceholderMessage(
                key: const ValueKey<String>('manga_discovery_feeds_failed'),
                icon: FushiIcons.cloudOff,
                tone: FushiPlaceholderTone.error,
                message: t.manga_discovery_load_failed,
                detail: feeds
                    .map((MangaDiscoverySourceFeed feed) => feed.displayName)
                    .join(' · '),
                action: FushiFilledButton.icon(
                  key: const ValueKey<String>('manga_discovery_retry_all'),
                  onPressed: _refresh,
                  icon: const FushiIcon(FushiIcons.refresh),
                  label: Text(t.retry),
                ),
              ),
            ),
          const SliverToBoxAdapter(
            child: DiscoveryLoadMoreFooter(loading: false),
          ),
        ],
      ),
    );
  }
}
