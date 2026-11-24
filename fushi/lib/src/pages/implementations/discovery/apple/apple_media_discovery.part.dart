part of '../../media_discovery_page.dart';

/// 书（小说 / 有声书）与游戏发现页的 Apple（Cupertino）画法（「浏览」页方案 A /
/// 宽屏货架）。业务状态与动作全在 [_MediaDiscoveryPageState]（同一份），这里只换
/// 画法：
///
/// - 第三层筛选（小说 / 有声书、游戏汉化分类）是搜索框右边的 pull-down（拍板点
///   4），不再出现 [FushiSelectableChip]；
/// - 「全部来源」引导态：iOS 档是一组 inset grouped 来源行（中性 glyph，能力 / 出处
///   降为副行）+ 组末「添加来源…」+ 组下说明文字（原提示条，去掉「浏览〈首个
///   源〉」快捷钮，拍板点 7）；macOS 档是方案 B 的「来源」lockup 横滑货架（货架头 +
///   「查看全部」展开成网格）；
/// - 文件夹行行首、可信 / 转载徽标、汉化 / 疑似漫画标签：中性 glyph 与彩色文字。
extension _AppleMediaDiscovery on _MediaDiscoveryPageState {
  /// 搜索框右边的 pull-down（第三层筛选）。
  List<Widget> _appleFilters() => <Widget>[
    if (widget.kinds.length > 1)
      AppleDiscoveryPullDown<DiscoveryMediaKind>(
        key: const ValueKey<String>('discovery_kind_pull_down'),
        keyPrefix: 'discovery_kind',
        values: widget.kinds,
        selected: _kind,
        labelOf: _kindLabel,
        onSelected: _selectKind,
      ),
    if (_gameTypeFilterVisible)
      AppleDiscoveryPullDown<_GameTypeFilter>(
        key: const ValueKey<String>('discovery_game_type_pull_down'),
        keyPrefix: 'discovery_game_type',
        values: _GameTypeFilter.values,
        selected: _gameTypeFilter,
        active: _gameTypeFilter != _GameTypeFilter.all,
        labelOf: (_GameTypeFilter f) => f.label,
        // 纯客户端过滤：不重新请求，只换渲染集合。
        onSelected: (_GameTypeFilter f) =>
            _updateState(() => _gameTypeFilter = f),
      ),
  ];

  /// 来源组下的说明文字：计数 + 引导句（没有来源时只写「还没有来源」）。
  String _appleSourcesFootnote(List<MediaDiscoverySource> sources) {
    if (sources.isEmpty) return t.discovery_guide_no_sources;
    final int browsable = sources
        .where((MediaDiscoverySource s) => s.capabilities.supportsBrowse)
        .length;
    return '${t.discovery_guide_capability_counts(browsable: browsable, searchOnly: sources.length - browsable)}\n'
        '${t.discovery_source_pick_hint}';
  }

  String _appleAddSourceHint() =>
      StoreRestrictedCapability.externalDiscovery.isAvailable
      ? t.manga_discovery_empty_action
      : t.discovery_source_add_hint_server;

  /// 「全部来源」+ 空查询的引导态（Apple）。
  Widget _buildAppleSourcePicker(
    BuildContext context,
    MediaDiscoveryService service,
  ) {
    final List<MediaDiscoverySource> sources = service.sourcesFor(_kind);
    return fushiAppleUsesMacMetrics(context)
        ? _buildAppleSourceShelf(context, sources)
        : _buildAppleSourceList(context, sources);
  }

  /// iOS 档：一组 inset grouped 来源行。
  Widget _buildAppleSourceList(
    BuildContext context,
    List<MediaDiscoverySource> sources,
  ) {
    final double page = appleDiscoveryPageInset(context);
    final VoidCallback? manage = widget.onManageSources;
    final List<Widget> rows = <Widget>[
      for (final MediaDiscoverySource source in sources)
        AppleDiscoverySourceRow(
          key: ValueKey<String>('discovery_source_pick_${source.id}'),
          focusId: FushiFocusId('discovery-source-pick-${source.id}'),
          name: source.displayName,
          caption: appleDiscoveryCaption(_sourceChips(source)),
          onTap: () => _selectSource(source.id),
        ),
      if (manage != null)
        AppleDiscoveryAddSourceRow(
          subtitle: _appleAddSourceHint(),
          onTap: manage,
        ),
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(page, 16, page, 24),
      child: FushiStaggeredEntrance(
        index: 0,
        child: AdaptiveSettingsSection(
          key: const ValueKey<String>('discovery_pick_banner'),
          title: '${_kindLabel(_kind)} · ${t.library_view_sources}',
          titleTrailing: manage == null
              ? null
              : AppleImportSectionAction(
                  label: t.manga_discovery_empty_action,
                  onTap: manage,
                ),
          footer: AppleDiscoveryFootnote(text: _appleSourcesFootnote(sources)),
          children: rows,
        ),
      ),
    );
  }

  /// macOS 档：「来源」lockup 横滑货架；「查看全部」展开成网格。
  Widget _buildAppleSourceShelf(
    BuildContext context,
    List<MediaDiscoverySource> sources,
  ) {
    final double page = appleDiscoveryPageInset(context);
    final VoidCallback? manage = widget.onManageSources;
    final List<Widget> cards = <Widget>[
      for (final MediaDiscoverySource source in sources)
        AppleDiscoveryLockup(
          key: ValueKey<String>('discovery_source_pick_${source.id}'),
          focusId: FushiFocusId('discovery-source-pick-${source.id}'),
          name: source.displayName,
          caption: appleDiscoveryCaption(_sourceChips(source)),
          actionLabel: source.capabilities.supportsBrowse
              ? appleDiscoveryBrowseLabel()
              : t.dialog_search,
          onTap: () {
            _selectSource(source.id);
            // 仅搜索源：点了直接把光标交给搜索框（来源 token 已出现在框前）。
            if (!source.capabilities.supportsBrowse) {
              _searchFocus.requestFocus();
            }
          },
        ),
      if (manage != null)
        AppleDiscoveryLockup(
          key: const ValueKey<String>('discovery_guide_manage'),
          focusId: const FushiFocusId('discovery-add-source'),
          name: '${t.discovery_source_add_title}…',
          caption: _appleAddSourceHint(),
          actionLabel: t.manga_discovery_empty_action,
          onTap: manage,
        ),
    ];
    final bool expanded = _appleSourcesExpanded;
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: page),
            child: AppleDiscoveryShelfHeader(
              key: const ValueKey<String>('discovery_pick_banner'),
              title: '${_kindLabel(_kind)} · ${t.library_view_sources}',
              subtitle: _appleSourcesFootnote(sources).replaceAll('\n', ' · '),
              viewAllKey: const ValueKey<String>('discovery_sources_view_all'),
              onViewAll: cards.length < 2
                  ? null
                  : () => _updateState(
                      () => _appleSourcesExpanded = !_appleSourcesExpanded,
                    ),
            ),
          ),
          const SizedBox(height: 8),
          if (expanded)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: page),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  const double gap = 16;
                  final double minWidth = appleDiscoveryLockupWidth(context);
                  final int columns =
                      ((constraints.maxWidth + gap) / (minWidth + gap))
                          .floor()
                          .clamp(1, 6);
                  final double tile =
                      (constraints.maxWidth - gap * (columns - 1)) / columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: <Widget>[
                      for (int i = 0; i < cards.length; i++)
                        SizedBox(
                          width: tile,
                          child: FushiStaggeredEntrance(
                            index: i,
                            child: cards[i],
                          ),
                        ),
                    ],
                  );
                },
              ),
            )
          else
            AppleDiscoveryLockupStrip(
              horizontalInset: page,
              children: <Widget>[
                for (int i = 0; i < cards.length; i++)
                  FushiStaggeredEntrance(index: i, child: cards[i]),
              ],
            ),
        ],
      ),
    );
  }

  /// 文件夹行行首（Apple）：中性 glyph + 文件夹字形。
  Widget _buildAppleFolderLeading(
    DiscoveryFolder entry,
    MediaDiscoveryService service,
  ) => AppleDiscoverySourceGlyph(
    name: _sourceDisplayName(service, entry.sourceId),
    iconData: FushiIcons.folder,
    size: kDiscoverySourceGlyphSize,
  );

  /// 资源标题（Apple）：可信 / 转载徽标降成彩色文字（方案 A「徽标改彩色文字」）。
  Widget _buildAppleResourceTitle(DiscoveryResourceItem item) {
    final Widget title = DiscoveryFitFileName(text: item.title);
    if (!item.trusted && !item.remake) return title;
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: title),
        const SizedBox(width: 8),
        Text(
          item.remake ? t.discovery_badge_remake : t.discovery_badge_trusted,
          key: ValueKey<String>(
            item.remake ? 'discovery_badge_remake' : 'discovery_badge_trusted',
          ),
          style: metrics
              .footnoteStyle(context)
              .copyWith(
                fontWeight: FontWeight.w600,
                color: item.remake ? apple.destructive : apple.success,
              ),
        ),
      ],
    );
  }

  /// 结果副行（Apple）：汉化 / 疑似漫画标签降为副行前的彩色文字。
  Widget _buildAppleResourceMeta(
    DiscoveryResourceItem item,
    MediaDiscoveryService service,
  ) {
    final FushiAppleColors apple = appleColorsOf(context);
    final DiscoveryGameLocalization? localization = item.gameLocalization;
    final TextStyle base = DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          if (localization != null)
            TextSpan(
              text:
                  '${_MediaDiscoveryPageState._localizationLabel(localization)} · ',
              style: base.copyWith(
                fontWeight: FontWeight.w600,
                color: apple.label,
              ),
            ),
          if (item.contentHint == DiscoveryContentHint.manga)
            TextSpan(
              text: '${t.discovery_content_hint_manga} · ',
              style: base.copyWith(
                fontWeight: FontWeight.w600,
                color: apple.warning,
              ),
            ),
          TextSpan(text: _subtitleFor(item, service)),
        ],
      ),
      key: localization == null
          ? null
          : ValueKey<String>('discovery_item_localization_${item.id}'),
    );
  }
}
