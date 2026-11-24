part of '../music_plugin_pages.dart';

// ---------------------------------------------------------------------------
// 推荐页（在线）的 Cupertino 布局：方案 A「主页式」（设计稿
// fushi/build/music_online_cupertino_design/index.html，用户 2026-11-24 拍板）。
//
// 只在 `isGlassDesign` 为真时由 [MusicPluginRecommendView] 分派过来；数据、刷新、
// 播放 / 菜单动作与 M3E 版同一份（[_HomeResult]、[_playTracks]、
// [musicPluginTrackMenu]、[musicPluginEntityMenu]…），这里只换版式：
// - 首块「继续收听」（宿主交进来的 leading）；
// - 「为你精选」一行高卡：每个插件的主卡（首个曲目段，未登录退成第一个歌单段的
//   头一张）+「我喜欢」+「私人电台」，卡下半是封面取色渐变；
// - 「最近播放」平封面货架（单插件视图不出）；
// - 每个插件一组（「全部」里带组头 + ⋯）：浏览分类、组内错误 / 无推荐、排行榜
//   卡（前 3 名）、歌曲分页列（4 行一列横滑）、歌单 / 专辑货架；
// - 之后是宿主交进来的服务器来源货架。
// iOS 下拉刷新；macOS 由工具栏刷新键（[MusicRecommendRefreshHandle]）与
// [ShortcutAction.musicRecommendRefresh]（默认 ⌘R）刷新；刷新中旧内容留着。
// ---------------------------------------------------------------------------

/// 推荐页「刷新全部来源」的外部入口（macOS 档工具栏刷新键、⌘R）：推荐列表挂上时
/// 登记自己的刷新，卸下时撤回；[refreshing] 期间工具栏键禁用。
class MusicRecommendRefreshHandle extends ChangeNotifier {
  Object? _owner;
  Future<void> Function()? _target;
  bool _refreshing = false;

  /// 有没有挂着的推荐列表（单个服务器来源时没有）。
  bool get available => _target != null;

  bool get refreshing => _refreshing;

  /// 重载全部来源（与下拉刷新同一个动作）；没有挂着的列表时什么都不做。
  Future<void> refresh() async => _target?.call();

  void _attach(Object owner, Future<void> Function() target) {
    _owner = owner;
    _target = target;
    notifyListeners();
  }

  void _detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _target = null;
    _refreshing = false;
    notifyListeners();
  }

  void _setRefreshing(Object owner, bool value) {
    if (!identical(_owner, owner) || _refreshing == value) return;
    _refreshing = value;
    notifyListeners();
  }
}

/// 一个插件推荐内容的版式归属（Apple 版）：主卡用的首个曲目段 / 退化歌单段、
/// 榜单段与它的榜单卡（带 previewTracks 的全部歌单，不只 2 张）。
typedef _AppleHomePlan = ({
  MusicPluginHomeSection? heroTracks,
  MusicPluginHomeSection? heroPlaylists,
  MusicPluginHomeSection? ranks,
  List<MusicPluginPlaylist> charts,
});

_AppleHomePlan _appleHomePlan(List<MusicPluginHomeSection> secs) {
  final MusicPluginHomeSection? heroTracks = secs
      .where((MusicPluginHomeSection s) => s.kind == MusicPluginHomeKind.tracks)
      .firstOrNull;
  final MusicPluginHomeSection? ranks = secs
      .where(
        (MusicPluginHomeSection s) =>
            s.kind == MusicPluginHomeKind.playlists &&
            s.items.whereType<MusicPluginPlaylist>().any(
              (MusicPluginPlaylist p) => p.previewTracks.isNotEmpty,
            ),
      )
      .firstOrNull;
  final MusicPluginHomeSection? heroPlaylists = heroTracks != null
      ? null
      : secs
            .where(
              (MusicPluginHomeSection s) =>
                  s != ranks &&
                  s.kind == MusicPluginHomeKind.playlists &&
                  s.items.isNotEmpty,
            )
            .firstOrNull;
  return (
    heroTracks: heroTracks,
    heroPlaylists: heroPlaylists,
    ranks: ranks,
    charts: ranks == null
        ? const <MusicPluginPlaylist>[]
        : ranks.items
              .whereType<MusicPluginPlaylist>()
              .where((MusicPluginPlaylist p) => p.previewTracks.isNotEmpty)
              .toList(),
  );
}

/// 打开某插件的「我喜欢」：已登录进平台的喜欢歌单，未登录去登录，拿不到 toast。
Future<void> _openPluginLiked(
  BuildContext context,
  AppModel app,
  MusicPluginLikeState s,
) async {
  if (!s.loggedIn) {
    await openMusicPluginLogin(context, appModel: app, manifest: s.manifest);
    return;
  }
  final MusicPluginPlaylist? playlist = s.playlist;
  if (playlist == null) {
    FushiToast.show(msg: t.music_liked_unavailable(name: s.manifest.name));
    return;
  }
  if (!context.mounted) return;
  await _push(
    context,
    MusicPluginCollectionPage.playlist(
      manifest: s.manifest,
      playlist: playlist,
    ),
  );
}

/// 推荐页 Apple 布局（见文件头）。
class _AppleMusicRecommendLayout extends ConsumerStatefulWidget {
  const _AppleMusicRecommendLayout({
    required this.data,
    required this.generation,
    required this.sources,
    required this.onRefresh,
    required this.showRecent,
    required this.showGroups,
    required this.relayVia,
    this.leading,
    this.trailing,
  });

  /// null = 首次加载（画骨架）。
  final List<_HomeResult>? data;
  final int generation;
  final List<MusicPluginManifest> sources;
  final Future<void> Function() onRefresh;

  /// 「最近播放」（跨来源，单插件视图不出）。
  final bool showRecent;

  /// 每个插件一组带组头（「全部」视图）；单插件视图不画组头。
  final bool showGroups;

  /// 经互联中继的插件 → 代跑它的设备名。
  final Map<String, String> relayVia;
  final Widget? leading;
  final List<Widget> Function(bool sliver)? trailing;

  @override
  ConsumerState<_AppleMusicRecommendLayout> createState() =>
      _AppleMusicRecommendLayoutState();
}

class _AppleMusicRecommendLayoutState
    extends ConsumerState<_AppleMusicRecommendLayout> {
  /// ⌘R（[ShortcutAction.musicRecommendRefresh]，用户可改键）：焦点在推荐页内时
  /// 刷新全部来源。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    for (final InputBinding binding in _appleShortcutBindings(
      context,
      ShortcutAction.musicRecommendRefresh,
    )) {
      if (binding.toActivator().accepts(event, HardwareKeyboard.instance)) {
        unawaited(widget.onRefresh());
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  List<FushiHeaderMoreEntry> _groupEntries(
    MusicPluginManifest m,
  ) => <FushiHeaderMoreEntry>[
    if (m.can(MusicPluginCapability.radio))
      FushiHeaderMoreEntry(
        key: ValueKey<String>('music-plugin-group-radio-${m.id}'),
        icon: FushiIcons.cast,
        label: t.music_plugin_radio_personal,
        onSelected: () => _startPluginRadio(context, ref, m),
      ),
    FushiHeaderMoreEntry(
      key: ValueKey<String>('music-plugin-home-refresh-${m.id}'),
      icon: FushiIcons.refresh,
      label: t.music_plugin_home_refresh,
      onSelected: widget.onRefresh,
    ),
    // 来源设置 = 插件管理页（安装 / 启停 / 登录）：只在本机跑插件时有；经中继
    // 的来源在本机没有管理页（iOS 合规：插件页签不出）。
    if (isMusicPluginSourcesAvailable)
      FushiHeaderMoreEntry(
        key: ValueKey<String>('music-plugin-group-settings-${m.id}'),
        icon: FushiIcons.settings,
        label: t.music_plugins_title,
        onSelected: () =>
            openMusicPluginManagement(context, appModel: ref.read(appProvider)),
      ),
  ];

  /// 一个插件的段落（盒子段落各包一层错峰进场）。
  void _pluginBlocks(_HomeResult r, void Function(Widget) add) {
    final MusicPluginManifest m = r.manifest;
    if (widget.showGroups) {
      final String? via = widget.relayVia[m.id];
      add(
        AppleMusicSourceGroupHeader(
          key: ValueKey<String>('music-plugin-group-${m.id}'),
          name: m.name,
          via: via == null ? null : t.music_plugin_relayed_via(name: via),
          menuKey: ValueKey<String>('music-plugin-group-more-${m.id}'),
          entries: _groupEntries(m),
        ),
      );
    }
    if (m.can(MusicPluginCapability.browse)) {
      add(
        _AppleMusicBrowseCategories(
          key: ValueKey<String>('music-plugin-browse-bar-${m.id}'),
          manifest: m,
        ),
      );
    }
    final double pad = appleMusicPagePadding(context);
    if (r.error != null) {
      add(
        _AppleMusicErrorBlock(
          key: ValueKey<String>('music-plugin-home-error-${m.id}'),
          message: musicPluginErrorText(r.error!),
          onRetry: widget.onRefresh,
        ),
      );
      return;
    }
    if (r.sections.isEmpty) {
      if (m.can(MusicPluginCapability.home)) {
        add(
          Padding(
            padding: EdgeInsets.fromLTRB(pad, 16, pad, 0),
            child: Text(
              t.music_plugin_home_empty,
              style: appleMusicText(
                context,
                size: 14,
                color: appleColorsOf(context).secondaryLabel,
              ),
            ),
          ),
        );
      }
      return;
    }
    final _AppleHomePlan plan = _appleHomePlan(r.sections);
    for (final MusicPluginHomeSection sec in r.sections) {
      if (sec == plan.heroTracks) continue;
      final List<Object> items = sec == plan.heroPlaylists
          ? sec.items.skip(1).toList()
          : sec == plan.ranks
          ? sec.items.where((Object o) => !plan.charts.contains(o)).toList()
          : sec.items;
      final VoidCallback? viewAll = switch (sec.more) {
        final MusicPluginBrowseQuery more => () => unawaited(
          openMusicPluginBrowseList(
            context,
            manifest: m,
            query: more,
            title: sec.title,
          ),
        ),
        null when sec.kind != MusicPluginHomeKind.tracks => () => unawaited(
          _push(context, MusicPluginHomeSectionPage(manifest: m, section: sec)),
        ),
        null => null,
      };
      final Key viewAllKey = ValueKey<String>(
        'music-plugin-home-view-all-${m.id}-${sec.id}',
      );
      if (sec == plan.ranks && plan.charts.isNotEmpty) {
        add(
          _AppleMusicSection(
            header: AppleMusicSectionHeader(
              title: sec.title,
              subtitle: sec.subtitle,
              onOpen: viewAll,
              openKey: viewAllKey,
            ),
            child: _AppleMusicChartShelf(
              key: ValueKey<String>('music-plugin-charts-${m.id}-${sec.id}'),
              manifest: m,
              charts: plan.charts,
            ),
          ),
        );
        final List<Object> rest = musicPluginShelfPreview(items);
        if (rest.any((Object o) => _pluginCoverTarget(m, o) != null)) {
          add(
            _AppleMusicEntityShelf(
              key: ValueKey<String>('music-plugin-home-${m.id}-${sec.id}'),
              manifest: m,
              items: rest,
            ),
          );
        }
        continue;
      }
      if (items.isEmpty) continue;
      switch (sec.kind) {
        case MusicPluginHomeKind.tracks:
          final List<MusicPluginTrack> tracks = items
              .whereType<MusicPluginTrack>()
              .toList();
          add(
            _AppleMusicSection(
              header: AppleMusicSectionHeader(
                title: sec.title,
                subtitle: sec.subtitle,
                onOpen: viewAll,
                openKey: viewAllKey,
                trailing: AppleMusicCapsuleButton(
                  key: ValueKey<String>(
                    'music-plugin-home-play-${m.id}-${sec.id}',
                  ),
                  icon: FushiIcons.play,
                  label: t.music_play_all,
                  onTap: () => _playTracks(ref, m.id, tracks),
                ),
              ),
              child: _AppleMusicSongColumns(
                key: ValueKey<String>('music-plugin-home-${m.id}-${sec.id}'),
                manifest: m,
                tracks: tracks
                    .take(_MusicPluginRecommendViewState._trackPreview)
                    .toList(),
              ),
            ),
          );
        case MusicPluginHomeKind.playlists || MusicPluginHomeKind.albums:
          final List<Object> preview = musicPluginShelfPreview(items);
          if (!preview.any((Object o) => _pluginCoverTarget(m, o) != null)) {
            continue;
          }
          add(
            _AppleMusicSection(
              header: AppleMusicSectionHeader(
                title: sec.title,
                subtitle: sec.subtitle,
                onOpen: viewAll,
                openKey: viewAllKey,
              ),
              child: _AppleMusicEntityShelf(
                key: ValueKey<String>('music-plugin-home-${m.id}-${sec.id}'),
                manifest: m,
                items: preview,
              ),
            ),
          );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<_HomeResult>? data = widget.data;
    if (data == null) return const AppleMusicRecommendSkeleton();
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final double pad = appleMusicPagePadding(context);
    final List<Widget> slivers = <Widget>[];
    int index = 0;
    void add(Widget w) => slivers.add(
      SliverToBoxAdapter(
        child: FushiStaggeredEntrance(index: index++, child: w),
      ),
    );
    if (widget.leading case final Widget leading) {
      add(
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: leading,
        ),
      );
    }
    add(
      _AppleMusicTopPicks(
        key: const ValueKey<String>('music-top-picks'),
        results: data,
        sources: widget.sources,
      ),
    );
    if (widget.showRecent) {
      slivers.add(
        _RecentPlays(
          key: const ValueKey<String>('music-recent-plays'),
          generation: widget.generation,
          sources: widget.sources,
          sliver: true,
        ),
      );
    }
    for (final _HomeResult r in data) {
      _pluginBlocks(r, add);
    }
    slivers.addAll(widget.trailing?.call(true) ?? const <Widget>[]);
    final EdgeInsets page = musicBrowsePagePadding(context);
    Widget scroll = CustomScrollView(
      key: const ValueKey<String>('music-plugin-recommend'),
      slivers: <Widget>[
        SliverPadding(
          padding: EdgeInsets.only(top: page.top, bottom: page.bottom),
          sliver: SliverMainAxisGroup(slivers: slivers),
        ),
      ],
    );
    // iOS 档下拉刷新（系统菊花，刷新中旧内容留着）；macOS 档走工具栏刷新键与 ⌘R。
    if (!metrics.desktop) {
      scroll = FushiRefreshIndicator(
        edgeOffset: MediaQuery.paddingOf(context).top,
        onRefresh: widget.onRefresh,
        child: scroll,
      );
    }
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: FushiEntranceScope(child: scroll),
    );
  }
}

/// 键盘绑定：用户改过键读注册表，否则平台默认表。
List<InputBinding> _appleShortcutBindings(
  BuildContext context,
  ShortcutAction action,
) {
  final FushiShortcutRegistry? registry = ShortcutBindingScope.maybeOf(context);
  if (registry != null && registry.isLoaded) {
    return registry.bindingsFor(action).keyboardBindings;
  }
  return ShortcutDefaults.forPlatform(
        defaultTargetPlatform,
      )[action]?.keyboardBindings ??
      const <InputBinding>[];
}

/// 段头 + 内容（一起随段错峰进场）。
class _AppleMusicSection extends StatelessWidget {
  const _AppleMusicSection({required this.header, required this.child});

  final Widget header;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[header, child],
  );
}

/// 插件出错：组内一块（警示图标 + 「加载失败」+ 插件给的错误文本 + 重试），其它
/// 来源照常。
class _AppleMusicErrorBlock extends StatelessWidget {
  const _AppleMusicErrorBlock({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double k = m.scale;
    final double pad = appleMusicPagePadding(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 16 * k, pad, 0),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: c.secondaryGroupedBackground,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(m.groupRadius),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 14 * k, vertical: 12 * k),
          child: Row(
            children: <Widget>[
              FushiIcon(FushiIcons.warning, size: 20 * k, color: c.warning),
              SizedBox(width: 12 * k),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      t.music_server_load_failed,
                      style: appleMusicText(context, size: 15 * k),
                    ),
                    Text(
                      message,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: appleMusicText(
                        context,
                        size: 12.5 * k,
                        color: c.secondaryLabel,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8 * k),
              AppleMusicCapsuleButton(
                icon: FushiIcons.refresh,
                label: t.retry,
                onTap: () => unawaited(onRetry()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「浏览分类」：全部作品 + 插件声明的各分面（Apple「按类别浏览」横滑块）。
class _AppleMusicBrowseCategories extends ConsumerStatefulWidget {
  const _AppleMusicBrowseCategories({super.key, required this.manifest});

  final MusicPluginManifest manifest;

  @override
  ConsumerState<_AppleMusicBrowseCategories> createState() =>
      _AppleMusicBrowseCategoriesState();
}

class _AppleMusicBrowseCategoriesState
    extends ConsumerState<_AppleMusicBrowseCategories> {
  late final Future<MusicPluginBrowseSchema> _schema = _browseSchemaOf(
    ref.read(appProvider),
    widget.manifest,
  );

  @override
  Widget build(BuildContext context) {
    final MusicPluginManifest m = widget.manifest;
    final double k = FushiAppleMetrics.of(context).scale;
    return FutureBuilder<MusicPluginBrowseSchema>(
      future: _schema,
      builder:
          (BuildContext context, AsyncSnapshot<MusicPluginBrowseSchema> s) {
            final List<MusicPluginBrowseOption> facets =
                s.data?.facets ?? const <MusicPluginBrowseOption>[];
            return _AppleMusicSection(
              header: AppleMusicSectionHeader(
                title: t.music_recommend_browse_categories,
              ),
              child: AppleMusicCarousel(
                itemCount: facets.length + 1,
                itemExtent: 150 * k,
                height: 96 * k,
                itemBuilder: (BuildContext context, int i) {
                  if (i == 0) {
                    return AppleMusicCategoryTile(
                      key: ValueKey<String>('music-plugin-browse-all-${m.id}'),
                      label: t.music_plugin_browse_all_works,
                      seed: 'all-works',
                      icon: FushiIcons.gridView,
                      onTap: () => unawaited(
                        openMusicPluginBrowseList(
                          context,
                          manifest: m,
                          query: const MusicPluginBrowseQuery(),
                        ),
                      ),
                    );
                  }
                  final MusicPluginBrowseOption f = facets[i - 1];
                  return AppleMusicCategoryTile(
                    key: ValueKey<String>(
                      'music-plugin-browse-facet-${m.id}-${f.id}',
                    ),
                    label: f.label,
                    seed: f.id,
                    icon: FushiIcons.tag,
                    onTap: () => unawaited(
                      _push(
                        context,
                        MusicPluginCatalogPage(manifest: m, facet: f),
                      ),
                    ),
                  );
                },
              ),
            );
          },
    );
  }
}

/// 歌单 / 专辑货架：平封面卡，点进详情，长按 / 右键是实体菜单。
class _AppleMusicEntityShelf extends ConsumerWidget {
  const _AppleMusicEntityShelf({
    super.key,
    required this.manifest,
    required this.items,
  });

  final MusicPluginManifest manifest;
  final List<Object> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Object> cards = <Object>[
      for (final Object o in items)
        if (_pluginCoverTarget(manifest, o) != null) o,
    ];
    final double k = FushiAppleMetrics.of(context).scale;
    final double w = 150 * k;
    return AppleMusicCarousel(
      itemCount: cards.length,
      itemExtent: w,
      height: AppleMusicCoverTile.heightFor(context, w),
      arrowCenter: w / 2,
      itemBuilder: (BuildContext context, int i) {
        final Object item = cards[i];
        final _PluginCoverTarget target = _pluginCoverTarget(manifest, item)!;
        return musicWithContextMenu(
          musicPluginEntityMenu(context, ref, manifest, item),
          AppleMusicCoverTile(
            key: ValueKey<String>('music-plugin-card-${target.id}'),
            title: target.title,
            subtitle: switch (item) {
              final MusicPluginPlaylist p => _pluginPlaylistSubtitle(p),
              final MusicPluginAlbum a => _pluginAlbumSubtitle(a),
              _ => target.subtitle,
            },
            cover: target.cover,
            width: w,
            onTap: () => unawaited(_push(context, target.page)),
          ),
        );
      },
    );
  }
}

/// 「排行榜」横滑：每张榜单一张卡（全部带前几首预览的榜单）。
class _AppleMusicChartShelf extends StatelessWidget {
  const _AppleMusicChartShelf({
    super.key,
    required this.manifest,
    required this.charts,
  });

  final MusicPluginManifest manifest;
  final List<MusicPluginPlaylist> charts;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double k = m.scale;
    final double w = (m.desktop ? 330 : 320) * k;
    return AppleMusicCarousel(
      itemCount: charts.length,
      itemExtent: w,
      height: _AppleMusicChartCard.heightFor(context),
      spacing: (m.desktop ? 16 : 12) * k,
      itemBuilder: (BuildContext context, int i) => _AppleMusicChartCard(
        key: ValueKey<String>(
          'music-plugin-rank-${manifest.id}-${charts[i].id}',
        ),
        manifest: manifest,
        playlist: charts[i],
      ),
    );
  }
}

/// 一张榜单卡：封面 56 + 榜名 + 副行，下面前 3 名（加粗数字名次，不用饼干徽章）。
/// 整卡点进歌单详情，长按 / 右键 = 收藏菜单。
class _AppleMusicChartCard extends ConsumerWidget {
  const _AppleMusicChartCard({
    super.key,
    required this.manifest,
    required this.playlist,
  });

  final MusicPluginManifest manifest;
  final MusicPluginPlaylist playlist;

  static const int _rows = 3;

  /// 卡头（封面 56 与两行文字取大者）高。
  static double _headExtent(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    return math.max(
      56 * k,
      appleMusicLineExtent(context, 16 * k) +
          appleMusicLineExtent(context, 12 * k),
    );
  }

  /// 一行名次（封面 36 与两行文字取大者，上下各留 5）高。
  static double _rowExtent(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    return math.max(
          36 * k,
          appleMusicLineExtent(context, 14.5 * k) +
              appleMusicLineExtent(context, 12.5 * k),
        ) +
        10 * k;
  }

  /// 卡总高：上 12 + 卡头 + 分隔 8 + [_rows] 行 + 下 6，与 build 同一份度量。
  static double heightFor(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    return 12 * k +
        _headExtent(context) +
        8 * k +
        _rows * _rowExtent(context) +
        6 * k;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    final double radius = 16 * k;
    final String sub = <String>[
      manifest.name,
      _pluginPlaylistSubtitle(playlist),
    ].where((String s) => s.isNotEmpty).join(' · ');
    final List<MusicPluginTrack> top = playlist.previewTracks
        .take(_rows)
        .toList();
    final Widget card = DecoratedBox(
      decoration: ShapeDecoration(
        color: c.secondaryGroupedBackground,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(14 * k, 12 * k, 14 * k, 6 * k),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              height: _headExtent(context) + 8 * k,
              padding: EdgeInsets.only(bottom: 8 * k),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: c.separator, width: 0.5),
                ),
              ),
              child: Row(
                children: <Widget>[
                  appleMusicCover(
                    cover: playlist.coverUrl,
                    size: 56 * k,
                    radius: 6 * k,
                    title: playlist.title,
                  ),
                  SizedBox(width: 12 * k),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          playlist.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: appleMusicText(
                            context,
                            size: 16 * k,
                            weight: FontWeight.w700,
                          ),
                        ),
                        if (sub.isNotEmpty)
                          Text(
                            sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: appleMusicText(
                              context,
                              size: 12 * k,
                              color: c.secondaryLabel,
                            ),
                          ),
                      ],
                    ),
                  ),
                  FushiIcon(
                    FushiIcons.chevronRight,
                    size: 18 * k,
                    color: c.tertiaryLabel,
                  ),
                ],
              ),
            ),
            for (int i = 0; i < top.length; i++)
              SizedBox(
                height: _rowExtent(context),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 22 * k,
                      child: Text(
                        '${i + 1}',
                        key: ValueKey<String>(
                          'music-plugin-rank-row-${playlist.id}-$i',
                        ),
                        textAlign: TextAlign.center,
                        style: appleMusicText(
                          context,
                          size: 17 * k,
                          weight: FontWeight.w700,
                        ),
                      ),
                    ),
                    SizedBox(width: 10 * k),
                    appleMusicCover(
                      cover: top[i].coverUrl,
                      size: 36 * k,
                      radius: 5 * k,
                    ),
                    SizedBox(width: 11 * k),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            top[i].title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: appleMusicText(context, size: 14.5 * k),
                          ),
                          if (top[i].artists.isNotEmpty)
                            Text(
                              top[i].artistText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: appleMusicText(
                                context,
                                size: 12.5 * k,
                                color: c.secondaryLabel,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    return musicWithContextMenu(
      musicPluginEntityMenu(context, ref, manifest, playlist),
      FushiHoverLift(
        builder: (BuildContext context, bool hovering) => FushiPressScale(
          child: FushiFocusable(
            onTap: () => unawaited(
              _push(
                context,
                MusicPluginCollectionPage.playlist(
                  manifest: manifest,
                  playlist: playlist,
                ),
              ),
            ),
            borderRadius: BorderRadius.circular(radius),
            ringPosition: DecorationPosition.foreground,
            child: card,
          ),
        ),
      ),
    );
  }
}

/// 歌曲分页列（Apple Music「热门歌曲」）：每列 4 行，横滑按整列吸附、露出下一列边；
/// macOS 宽窗一屏 3 列。
class _AppleMusicSongColumns extends StatelessWidget {
  const _AppleMusicSongColumns({
    super.key,
    required this.manifest,
    required this.tracks,
  });

  final MusicPluginManifest manifest;
  final List<MusicPluginTrack> tracks;

  @override
  Widget build(BuildContext context) => AppleMusicSongColumns(
    itemCount: tracks.length,
    columnKeyPrefix: 'music-plugin-song-column',
    rowBuilder: (BuildContext context, int i, bool separator) =>
        _AppleMusicSongRow(
          manifest: manifest,
          tracks: tracks,
          index: i,
          separator: separator,
        ),
  );
}

/// 一行插件歌曲（[AppleMusicSongRow]）：艺人 · 专辑 · 备注 / 不可播放（半透明）、
/// MV 标（可点）、⋯ 菜单；长按 / 右键同一份曲目菜单；分页列里不画时长。
class _AppleMusicSongRow extends ConsumerWidget {
  const _AppleMusicSongRow({
    required this.manifest,
    required this.tracks,
    required this.index,
    required this.separator,
  });

  final MusicPluginManifest manifest;
  final List<MusicPluginTrack> tracks;
  final int index;
  final bool separator;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MusicPluginTrack track = tracks[index];
    final MusicItemMenu? menu = musicPluginTrackMenu(
      context,
      ref,
      manifest,
      track,
    );
    final VoidCallback? mv = _mvAction(context, ref, manifest, track);
    final String subtitle = <String>[
      if (track.artists.isNotEmpty) track.artistText,
      ?track.albumTitle,
      if (!track.playable) t.music_plugin_unplayable else ?track.note,
    ].join(' · ');
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    final String uid = musicPluginTrackUid(manifest.id, track.id);
    return Opacity(
      key: ValueKey<String>('music-plugin-track-${track.id}'),
      opacity: track.playable ? 1 : 0.45,
      child: musicWithContextMenu(
        menu,
        MusicNowPlayingMatch(
          listenable: engine,
          isCurrent: () => engine.current?.trackUid == uid,
          builder: (BuildContext context, bool playing) => AppleMusicSongRow(
            title: track.title,
            subtitle: subtitle,
            cover: track.coverUrl,
            playing: playing,
            separator: separator,
            onTap: track.playable
                ? () => _playTracks(ref, manifest.id, tracks, start: index)
                : null,
            trailing: <Widget>[
              if (mv != null)
                AppleMusicMvBadge(
                  key: ValueKey<String>('music-plugin-track-mv-${track.id}'),
                  onTap: mv,
                  semanticLabel: t.music_mv_play,
                ),
              ?menu?.button(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「为你精选」(Top Picks)：每个插件的主卡 + 我喜欢 + 私人电台，一行高卡横滑；
/// 前 3 张逐张错峰进场。
class _AppleMusicTopPicks extends ConsumerWidget {
  const _AppleMusicTopPicks({
    super.key,
    required this.results,
    required this.sources,
  });

  final List<_HomeResult> results;
  final List<MusicPluginManifest> sources;

  List<Widget> _cards(
    BuildContext context,
    WidgetRef ref,
    AppModel app,
    List<MusicPluginLikeState> likes,
  ) {
    final List<Widget> out = <Widget>[];
    for (final _HomeResult r in results) {
      final MusicPluginManifest m = r.manifest;
      if (r.error == null && r.sections.isNotEmpty) {
        final _AppleHomePlan plan = _appleHomePlan(r.sections);
        if (plan.heroTracks case final MusicPluginHomeSection sec) {
          final List<MusicPluginTrack> tracks = sec.items
              .whereType<MusicPluginTrack>()
              .toList();
          out.add(
            _AppleTopPickCard(
              key: ValueKey<String>('music-plugin-hero-${m.id}-${sec.id}'),
              eyebrow: m.name,
              title: sec.title,
              meta: t.music_plugin_hero_track_count(n: sec.items.length),
              covers: <String?>[
                for (final MusicPluginTrack tr in tracks.take(4)) tr.coverUrl,
              ],
              badge: FushiIcons.star,
              // 卡片本体推入「段落曲目」二级页（拍板 Q4），卡上仍留 播放 / 随机。
              onTap: () => unawaited(
                _push(
                  context,
                  _AppleMusicSectionTracksPage(manifest: m, section: sec),
                ),
              ),
              actions: <_TopPickAction>[
                (
                  key: ValueKey<String>('music-plugin-hero-play-${m.id}'),
                  icon: FushiIcons.play,
                  label: t.music_play_all,
                  onTap: () => _playTracks(ref, m.id, tracks),
                ),
                (
                  key: ValueKey<String>('music-plugin-hero-shuffle-${m.id}'),
                  icon: FushiIcons.shuffle,
                  label: t.music_shuffle_play,
                  onTap: () => _playTracks(ref, m.id, tracks, shuffle: true),
                ),
              ],
            ),
          );
        } else if (plan.heroPlaylists case final MusicPluginHomeSection sec) {
          final MusicPluginPlaylist? first = sec.items
              .whereType<MusicPluginPlaylist>()
              .firstOrNull;
          if (first != null) {
            void open() => unawaited(
              _push(
                context,
                MusicPluginCollectionPage.playlist(
                  manifest: m,
                  playlist: first,
                ),
              ),
            );
            out.add(
              _AppleTopPickCard(
                key: ValueKey<String>('music-plugin-hero-${m.id}'),
                eyebrow: sec.title,
                title: first.title,
                meta: first.owner ?? '',
                covers: <String?>[first.coverUrl],
                badge: FushiIcons.music,
                onTap: open,
                actions: <_TopPickAction>[
                  (
                    key: ValueKey<String>('music-plugin-hero-open-${m.id}'),
                    icon: FushiIcons.chevronRight,
                    label: t.music_plugin_hero_open,
                    onTap: open,
                  ),
                ],
              ),
            );
          }
        }
      }
      for (final MusicPluginLikeState s in likes) {
        if (s.manifest.id != m.id) continue;
        out.add(
          _AppleTopPickCard(
            key: ValueKey<String>('music-liked-${m.id}'),
            eyebrow: m.name,
            title: t.music_liked_title,
            meta: s.loggedIn ? m.name : t.music_liked_login_hint(name: m.name),
            covers: <String?>[s.playlist?.coverUrl],
            badge: FushiIcons.favorite,
            onTap: () => unawaited(_openPluginLiked(context, app, s)),
            actions: const <_TopPickAction>[],
          ),
        );
      }
      if (m.can(MusicPluginCapability.radio)) {
        out.add(
          _AppleTopPickCard(
            key: ValueKey<String>('music-plugin-radio-${m.id}'),
            eyebrow: m.name,
            title: t.music_plugin_radio_personal,
            meta: t.music_plugin_radio_personal_hint,
            covers: const <String?>[],
            badge: FushiIcons.cast,
            onTap: () => unawaited(_startPluginRadio(context, ref, m)),
            actions: <_TopPickAction>[
              (
                key: ValueKey<String>('music-plugin-radio-play-${m.id}'),
                icon: FushiIcons.play,
                label: t.music_play_all,
                onTap: () => unawaited(_startPluginRadio(context, ref, m)),
              ),
            ],
          ),
        );
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel app = ref.watch(appProvider);
    final MusicPluginFavorites? favorites = app.musicSession.favorites;
    Widget build(List<MusicPluginLikeState> likes) {
      final List<Widget> cards = _cards(context, ref, app, likes);
      if (cards.isEmpty) return const SizedBox.shrink();
      final FushiAppleMetrics m = FushiAppleMetrics.of(context);
      final double k = m.scale;
      final double w = (m.desktop ? 186 : 250) * k;
      return _AppleMusicSection(
        header: AppleMusicSectionHeader(title: t.music_recommend_top_picks),
        child: AppleMusicCarousel(
          itemCount: cards.length,
          itemExtent: w,
          spacing: (m.desktop ? 16 : 12) * k,
          height: _AppleTopPickCard.heightFor(context, w),
          arrowCenter: _AppleTopPickCard.eyebrowHeight(context) + w * 0.68,
          itemBuilder: (BuildContext context, int i) => i < 3
              ? FushiStaggeredEntrance(index: i, child: cards[i])
              : cards[i],
        ),
      );
    }

    if (favorites == null) return build(const <MusicPluginLikeState>[]);
    return ListenableBuilder(
      listenable: favorites,
      builder: (BuildContext context, _) => build(<MusicPluginLikeState>[
        for (final MusicPluginLikeState s in favorites.states)
          if (sources.any((MusicPluginManifest m) => m.id == s.manifest.id)) s,
      ]),
    );
  }
}

typedef _TopPickAction = ({
  Key key,
  IconData icon,
  String label,
  VoidCallback onTap,
});

/// 一张「为你精选」高卡：卡上方 eyebrow（来源 / 段名）；卡上半封面（曲目段 2×2
/// 拼封面），下半取自封面的渐变文字区 + 标题 + 副行 + 按钮。整卡可点；按压缩放、
/// 悬停抬升。封面取色只用在这里（拍板 Q11）。
class _AppleTopPickCard extends StatelessWidget {
  const _AppleTopPickCard({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.meta,
    required this.covers,
    required this.badge,
    required this.onTap,
    required this.actions,
  });

  final String eyebrow;
  final String title;
  final String meta;
  final List<String?> covers;
  final IconData badge;
  final VoidCallback onTap;
  final List<_TopPickAction> actions;

  /// 眉标行高：一行 12.5 号字 + 下方 6 间距。
  static double eyebrowHeight(BuildContext context) =>
      appleMusicLineExtent(
        context,
        12.5 * FushiAppleMetrics.of(context).scale,
      ) +
      6 * FushiAppleMetrics.of(context).scale;

  static double heightFor(BuildContext context, double w) =>
      eyebrowHeight(context) + (w * 1.36).roundToDouble();

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double k = FushiAppleMetrics.of(context).scale;
        final double w = c.maxWidth;
        final double h = (w * 1.36).roundToDouble();
        final double radius = 16 * k;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              height: eyebrowHeight(context),
              child: Padding(
                padding: EdgeInsetsDirectional.only(start: 2 * k),
                child: Text(
                  eyebrow,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: appleMusicText(
                    context,
                    size: 12.5 * k,
                    color: apple.secondaryLabel,
                  ),
                ),
              ),
            ),
            _RecommendCoverPalette(
              image: musicCoverImageProvider(
                covers.where((String? c) => c != null).firstOrNull,
                size: 128,
              ),
              builder: (BuildContext context, FushiCoverBlockColors colors) {
                final Color tint = colors.container;
                final Color on = colors.onContainer;
                return FushiHoverLift(
                  builder: (BuildContext context, bool hovering) =>
                      FushiPressScale(
                        child: FushiFocusable(
                          onTap: onTap,
                          borderRadius: BorderRadius.circular(radius),
                          ringPosition: DecorationPosition.foreground,
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                              color: tint,
                              shape: RoundedSuperellipseBorder(
                                borderRadius: BorderRadius.circular(radius),
                              ),
                              shadows: <BoxShadow>[
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: hovering ? 0.24 : 0.12,
                                  ),
                                  blurRadius: hovering ? 26 : 18,
                                  offset: Offset(0, hovering ? 10 : 6),
                                ),
                              ],
                            ),
                            child: appleMusicSquircle(
                              radius: radius,
                              child: SizedBox(
                                width: w,
                                height: h,
                                child: Stack(
                                  children: <Widget>[
                                    Positioned(
                                      left: 0,
                                      top: 0,
                                      child: _appleCoverArt(covers, w, title),
                                    ),
                                    PositionedDirectional(
                                      start: 10 * k,
                                      top: 10 * k,
                                      child: Container(
                                        padding: EdgeInsets.all(5 * k),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.28,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        child: FushiIcon(
                                          badge,
                                          size: 12 * k,
                                          color: Colors.white,
                                          fill: 1,
                                        ),
                                      ),
                                    ),
                                    Positioned.fill(
                                      top: w * 0.5,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: <Color>[
                                              tint.withValues(alpha: 0),
                                              tint,
                                            ],
                                            stops: const <double>[0, 0.38],
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: 14 * k,
                                      right: 14 * k,
                                      bottom: 14 * k,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: <Widget>[
                                          Text(
                                            title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: appleMusicText(
                                              context,
                                              size: 19 * k,
                                              weight: FontWeight.w700,
                                              color: on,
                                              height: 1.15,
                                            ),
                                          ),
                                          if (meta.isNotEmpty)
                                            Padding(
                                              padding: EdgeInsets.only(
                                                top: 4 * k,
                                              ),
                                              child: Text(
                                                meta,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: appleMusicText(
                                                  context,
                                                  size: 12.5 * k,
                                                  color: on.withValues(
                                                    alpha: 0.82,
                                                  ),
                                                  height: 1.35,
                                                ),
                                              ),
                                            ),
                                          if (actions.isNotEmpty)
                                            Padding(
                                              padding: EdgeInsets.only(
                                                top: 10 * k,
                                              ),
                                              child: Wrap(
                                                spacing: 8 * k,
                                                runSpacing: 6 * k,
                                                children: <Widget>[
                                                  for (
                                                    int i = 0;
                                                    i < actions.length;
                                                    i++
                                                  )
                                                    AppleMusicCapsuleButton(
                                                      key: actions[i].key,
                                                      icon: actions[i].icon,
                                                      label: actions[i].label,
                                                      onTap: actions[i].onTap,
                                                      background: i == 0
                                                          ? on
                                                          : on.withValues(
                                                              alpha: 0.16,
                                                            ),
                                                      foreground: i == 0
                                                          ? tint
                                                          : on,
                                                    ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

/// 精选卡 / 段落曲目页头的封面：≥4 张封面拼 2×2，否则头一张（没有就按标题生成）。
Widget _appleCoverArt(List<String?> covers, double w, String title) {
  final List<String?> shown = covers.where((String? c) => c != null).toList();
  if (shown.length >= 4) {
    final double half = w / 2;
    return SizedBox.square(
      dimension: w,
      child: Wrap(
        children: <Widget>[
          for (final String? c in shown.take(4))
            SizedBox.square(
              dimension: half,
              child: MusicCover(
                coverPath: c,
                size: half,
                borderRadius: BorderRadius.zero,
              ),
            ),
        ],
      ),
    );
  }
  return SizedBox.square(
    dimension: w,
    child: MusicCover(
      coverPath: shown.firstOrNull,
      size: w,
      title: title,
      borderRadius: BorderRadius.zero,
    ),
  );
}

/// 「段落曲目」二级页（拍板 Q4，只在 Apple 档有入口）：「为你精选」主卡点进来，
/// 列出该段全部曲目——行与其它曲目列表同一组件与菜单（[musicPluginItemTile]），
/// 头部 2×2 拼封面 + 来源 · 首数 + 播放 / 随机。
class _AppleMusicSectionTracksPage extends ConsumerWidget {
  const _AppleMusicSectionTracksPage({
    required this.manifest,
    required this.section,
  });

  final MusicPluginManifest manifest;
  final MusicPluginHomeSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Object> items = section.items
        .whereType<MusicPluginTrack>()
        .cast<Object>()
        .toList();
    final List<MusicPluginTrack> tracks = items
        .cast<MusicPluginTrack>()
        .toList();
    return musicBrowseScaffold(
      context,
      title: section.title,
      body: (BuildContext context) {
        final FushiAppleColors c = appleColorsOf(context);
        final double k = FushiAppleMetrics.of(context).scale;
        final Widget header = Padding(
          padding: EdgeInsets.only(bottom: 12 * k),
          child: Row(
            children: <Widget>[
              appleMusicSquircle(
                radius: 10 * k,
                child: SizedBox.square(
                  dimension: 120 * k,
                  child: _appleCoverArt(
                    <String?>[
                      for (final MusicPluginTrack tr in tracks.take(4))
                        tr.coverUrl,
                    ],
                    120 * k,
                    section.title,
                  ),
                ),
              ),
              SizedBox(width: 14 * k),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${manifest.name} · '
                      '${t.music_plugin_hero_track_count(n: tracks.length)}',
                      style: appleMusicText(
                        context,
                        size: 13 * k,
                        color: c.secondaryLabel,
                      ),
                    ),
                    if (section.subtitle case final String s)
                      Text(
                        s,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: appleMusicText(
                          context,
                          size: 13 * k,
                          color: c.secondaryLabel,
                        ),
                      ),
                    SizedBox(height: 10 * k),
                    Wrap(
                      spacing: 8 * k,
                      runSpacing: 6 * k,
                      children: <Widget>[
                        AppleMusicCapsuleButton(
                          key: const ValueKey<String>(
                            'music-plugin-section-tracks-play',
                          ),
                          icon: FushiIcons.play,
                          label: t.music_play_all,
                          background: c.accent,
                          foreground: c.onAccent,
                          onTap: () => _playTracks(ref, manifest.id, tracks),
                        ),
                        AppleMusicCapsuleButton(
                          key: const ValueKey<String>(
                            'music-plugin-section-tracks-shuffle',
                          ),
                          icon: FushiIcons.shuffle,
                          label: t.music_shuffle_play,
                          onTap: () => _playTracks(
                            ref,
                            manifest.id,
                            tracks,
                            shuffle: true,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        return FushiEntranceScope(
          child: ListView.builder(
            key: ValueKey<String>(
              'music-plugin-section-tracks-${manifest.id}-${section.id}',
            ),
            padding: musicBrowsePagePadding(context),
            itemCount: items.length + 1,
            itemBuilder: fushiStaggeredItemBuilder(
              (BuildContext context, int i) => i == 0
                  ? header
                  : musicPluginItemTile(context, ref, manifest, items, i - 1),
            ),
          ),
        );
      },
    );
  }
}
