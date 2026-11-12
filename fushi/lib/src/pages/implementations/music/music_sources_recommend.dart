/// 曲库页「推荐」：顶部来源 chip 行（全部 + 每个在线来源，顺序 / 显示取自「来源」页），
/// 设计稿 fushi/build/music_design/music_sources.html ②（方案 A，用户 2026-11-01 选定）。
///
/// - **全部**：插件推荐（[MusicPluginRecommendView]）之后，每个服务器来源一排专辑
///   （Apple Music = 热门榜，Jellyfin / OpenSubsonic = 最新专辑），「查看全部」切到该来源；
/// - **单个插件**：只看这个插件的推荐；
/// - **单个服务器**：就地显示它的专辑 / 艺人分区（[MusicServerBrowsePage] 内嵌），
///   Apple Music 在分区切换旁边带地区选择。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart'
    show kAppleMusicStorefrontChoices;
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/music_online_sources.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_track_row_surface.dart'
    show MusicSectionActionKind, musicSectionAction;
import 'package:fushi/src/pages/shared/library_section_tabs.dart';
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockSize;
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart'
    show kFushiCoverBlockHeight;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 有推荐首页可看的来源：声明了 home 的插件，或有浏览树的服务器（YouTube 内置音源只有搜索）。
bool musicSourceHasRecommend(MusicOnlineSource s) => switch (s) {
  MusicPluginOnlineSource(:final MusicPluginManifest manifest) => manifest.can(
    MusicPluginCapability.home,
  ),
  MusicServerOnlineSource(:final MusicServerBrowser browser) =>
    musicServerHasBrowse(browser.kind),
  _ => false,
};

/// 「全部来源」在来源页签里的段值（[LibrarySectionTabs] 的段值不能为 null）。
const String kMusicRecommendAllSources = 'music-recommend-all';

/// [selected] 在 [sources] 里还在时原样返回，否则 null（= 全部）：选中的来源被关掉 /
/// 停用 / 删除后，页签选中与面板内容一起回到「全部」。
String? musicRecommendEffectiveSource(
  List<MusicOnlineSource> sources,
  String? selected,
) => sources.any((MusicOnlineSource s) => s.key == selected) ? selected : null;

/// 推荐页的来源页签（全部 + 每个来源）：页头大字顶栏里交给大字行
/// （[FushiFloatingChromeBar.secondary]），由 [LibrarySectionTabs] 画成与曲库二级
/// 页签同款的连体按钮组（[FushiMastheadSegmentedTabs]）。每段文字挂
/// `music-recommend-source-<key | all>`（与旧 chip 同一个 key）。
Widget musicRecommendSourceTabs({
  required List<MusicOnlineSource> sources,
  required String? selected,
  required ValueChanged<String?> onSelect,
}) {
  final String? effective = musicRecommendEffectiveSource(sources, selected);
  return LibrarySectionTabs<String>(
    tabs: <LibrarySectionTab<String>>[
      LibrarySectionTab<String>(
        value: kMusicRecommendAllSources,
        label: t.music_search_source_all,
        labelKey: const ValueKey<String>('music-recommend-source-all'),
      ),
      for (final MusicOnlineSource s in sources)
        LibrarySectionTab<String>(
          value: s.key,
          label: s.name,
          labelKey: ValueKey<String>('music-recommend-source-${s.key}'),
        ),
    ],
    selected: effective ?? kMusicRecommendAllSources,
    onChanged: (String v) =>
        onSelect(v == kMusicRecommendAllSources ? null : v),
    focusIdPrefix: 'music-recommend-source',
    secondary: true,
  );
}

class MusicSourcesRecommendView extends ConsumerStatefulWidget {
  const MusicSourcesRecommendView({
    super.key,
    required this.sources,
    required this.onSourcesChanged,
    this.selectedSource,
    this.onSelectSource,
    this.leading,
  });

  /// 已排序、显示中的来源（调用方已按 [musicSourceHasRecommend] 过滤）。
  final List<MusicOnlineSource> sources;

  /// 来源本身变了（如 Apple Music 换地区）：调用方重读来源。
  final VoidCallback onSourcesChanged;

  /// 非 null = 来源选择由宿主持有并画在页头大字行里（[musicRecommendSourceTabs]）：
  /// 本页不再画自己的 chip 行，选中值读 [selectedSource]、改动经它回报（「查看全部」
  /// 切到某来源也走它）。null = 本页自持选中值、自己画 chip 行（墨水屏 /
  /// 独立挂载；两种库页布局下都由宿主持有）。
  final ValueChanged<String?>? onSelectSource;

  /// 宿主持有时的选中来源 key；null = 全部。
  final String? selectedSource;

  /// 插件推荐列表最前面跟着滚动的一块（曲库「继续收听」，宿主在页头大字浮在内容上
  /// 时交进来，不再钉在列表上方）。只在插件推荐面板（全部 / 单个插件）里出现。
  final Widget? leading;

  @override
  ConsumerState<MusicSourcesRecommendView> createState() =>
      _MusicSourcesRecommendViewState();
}

class _MusicSourcesRecommendViewState
    extends ConsumerState<MusicSourcesRecommendView> {
  /// 用户点选的来源 key；null = 全部。来源消失后它可能悬空，显示一律走 [_selectedSource]。
  /// 宿主持有选中值（[MusicSourcesRecommendView.onSelectSource]）时不用它。
  String? _ownSelected;

  bool get _hosted => widget.onSelectSource != null;

  String? get _selected => _hosted ? widget.selectedSource : _ownSelected;

  MusicOnlineSource? get _selectedSource {
    for (final MusicOnlineSource s in widget.sources) {
      if (s.key == _selected) return s;
    }
    return null;
  }

  List<MusicPluginManifest> get _plugins => <MusicPluginManifest>[
    for (final MusicOnlineSource s in widget.sources)
      if (s is MusicPluginOnlineSource) s.manifest,
  ];

  void _select(String? key) {
    final ValueChanged<String?>? hosted = widget.onSelectSource;
    if (hosted != null) {
      hosted(key);
      return;
    }
    setState(() => _ownSelected = key);
  }

  Future<void> _setStorefront(String sf) async {
    await ref.read(appProvider).prefsRepo.setMusicAppleMusicStorefront(sf);
    widget.onSourcesChanged();
  }

  Widget _chips(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // chip 选中与面板内容同一个有效值：选中的来源没了（被关掉 / 停用 / 删除）两者一起回到「全部」。
    final String? effective = _selectedSource?.key;
    Widget chip(String? key, String label) => Padding(
      padding: EdgeInsetsDirectional.only(end: tokens.spacing.gap / 2),
      child: FushiPressScale(
        child: FushiChoiceChip(
          key: ValueKey<String>('music-recommend-source-${key ?? 'all'}'),
          label: Text(label),
          selected: effective == key,
          onSelected: (_) => _select(key),
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap / 2,
        tokens.spacing.page,
        0,
      ),
      child: HorizontalDragScrollable(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              chip(null, t.music_search_source_all),
              for (final MusicOnlineSource s in widget.sources)
                chip(s.key, s.name),
            ],
          ),
        ),
      ),
    );
  }

  /// 单个服务器来源的就地浏览（[MusicServerBrowsePage]）顶上是一排固定的分区切换，
  /// 不按 `MediaQuery` 顶部内边距让位。宿主让页头大字浮在内容上时
  /// （[MusicSourcesRecommendView.onSelectSource]），这一面板整体排在大字下面，
  /// 它的竖向滚动 / 版面通知不往上报——大字保持展开，不留收起后的空带。
  Widget _pinnedBelowChrome(BuildContext context, Widget child) {
    if (!_hosted) return child;
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (ScrollMetricsNotification n) =>
              n.metrics.axis == Axis.vertical,
          child: NotificationListener<ScrollNotification>(
            onNotification: (ScrollNotification n) =>
                n.metrics.axis == Axis.vertical,
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final MusicOnlineSource? s = _selectedSource;
    return switch (s) {
      MusicPluginOnlineSource(:final MusicPluginManifest manifest) =>
        MusicPluginRecommendView(
          key: ValueKey<String>('music-recommend-${s.key}'),
          sources: <MusicPluginManifest>[manifest],
          showPersonal: false,
          leading: widget.leading,
        ),
      MusicServerOnlineSource(:final MusicServerBrowser browser) =>
        _pinnedBelowChrome(
          context,
          MusicServerBrowsePage(
            // 换地区 = 换 serverId：按 serverId 建 key，新地区重新拉榜。
            key: ValueKey<String>('music-recommend-${browser.serverId}'),
            browser: browser,
            embedded: true,
            trailing: browser.kind == MusicServerKind.appleMusic
                ? _AppleMusicRegionButton(
                    storefront: ref
                        .read(appProvider)
                        .prefsRepo
                        .musicAppleMusicStorefront,
                    onChanged: (String v) => unawaited(_setStorefront(v)),
                  )
                : null,
          ),
        ),
      _ => MusicPluginRecommendView(
        key: const ValueKey<String>('music-recommend-all'),
        sources: _plugins,
        leading: widget.leading,
        trailing: (bool sliver) => <Widget>[
          for (final MusicOnlineSource o in widget.sources)
            if (o is MusicServerOnlineSource)
              _ServerShelf(
                // 身份跟着数据源走：Apple Music 换地区 = 换 serverId，换一排重新拉榜。
                key: ValueKey<String>(
                  'music-recommend-shelf-${o.browser.serverId}',
                ),
                browser: o.browser,
                onViewAll: () => _select(o.key),
                sliver: sliver,
              ),
        ],
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 宿主持有选中值时，来源页签画在页头大字行里（[musicRecommendSourceTabs]）。
        if (!_hosted) _chips(context),
        Expanded(
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            child: KeyedSubtree(
              key: ValueKey<String>(
                'music-recommend-pane-${_selectedSource?.key ?? 'all'}',
              ),
              // 每个来源面板自己的主滚动控制器：切换淡出期间新旧两个面板同时在树上
              // （与曲库页分区切换同一做法）。
              child: SectionPrimaryScrollScope(child: _content(context)),
            ),
          ),
        ),
      ],
    );
  }
}

/// 「全部」里一个服务器来源的一排专辑（第一页的前 [_limit] 张）。
class _ServerShelf extends StatefulWidget {
  const _ServerShelf({
    super.key,
    required this.browser,
    required this.onViewAll,
    this.sliver = false,
  });

  final MusicServerBrowser browser;
  final VoidCallback onViewAll;

  /// true：推荐页是色块版式（[musicRecommendPosterMode]），build 出 sliver，专辑排成
  /// 封面色块；false：原横排，build 出盒子。
  final bool sliver;

  @override
  State<_ServerShelf> createState() => _ServerShelfState();
}

class _ServerShelfState extends State<_ServerShelf> {
  static const int _limit = 12;
  static const double _cardWidth = 150;

  late Future<MusicServerPage<MusicServerAlbum>> _page = widget.browser
      .listAlbums(offset: 0);

  @override
  void didUpdateWidget(_ServerShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 来源重读后是新的浏览器实例（连接配置 / 地区可能变了）：按新实例重新取。
    if (!identical(oldWidget.browser, widget.browser)) {
      _page = widget.browser.listAlbums(offset: 0);
    }
  }

  void _retry() => setState(() {
    _page = widget.browser.listAlbums(offset: 0);
  });

  Widget _header() => musicRecommendSectionHeader(
    title: widget.browser.displayName,
    actions: <Widget>[
      musicSectionAction(
        key: ValueKey<String>(
          'music-recommend-view-all-${widget.browser.serverId}',
        ),
        kind: MusicSectionActionKind.viewAll,
        label: t.music_sources_view_all,
        onPressed: widget.onViewAll,
      ),
    ],
  );

  /// 色块版式：段标题 + 前 [kMusicRecommendShelfRows] 行专辑封面色块（与曲库网格里
  /// 混排的服务器专辑同一张卡 [MusicServerAlbumBlockCard]）；加载 / 出错占一块的高。
  Widget _buildSliver(BuildContext context) {
    Widget placeholder(Widget child) => SliverToBoxAdapter(
      child: SizedBox(height: kFushiCoverBlockHeight, child: child),
    );
    return SliverMainAxisGroup(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: FushiStaggeredEntrance(index: 0, child: _header()),
        ),
        FutureBuilder<MusicServerPage<MusicServerAlbum>>(
          future: _page,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<MusicServerPage<MusicServerAlbum>> snap,
              ) {
                if (snap.hasError) {
                  return placeholder(
                    musicBrowseErrorView(context, snap.error!, _retry),
                  );
                }
                final List<MusicServerAlbum>? albums = snap.data?.items
                    .take(_limit)
                    .toList();
                if (albums == null) {
                  return placeholder(const FushiLoadingView());
                }
                return SliverMusicRecommendBlocks(
                  itemCount: albums.length,
                  itemBuilder:
                      (BuildContext context, int i, FushiCoverBlockSize size) =>
                          MusicServerAlbumBlockCard(
                            key: ValueKey<String>(
                              'music-recommend-album-${albums[i].id}',
                            ),
                            browser: widget.browser,
                            album: albums[i],
                            size: size,
                          ),
                );
              },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sliver) return _buildSliver(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double height =
        _cardWidth / kShelfAlbumAspectRatio + ShelfCardMeta.heightFor(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(),
        FutureBuilder<MusicServerPage<MusicServerAlbum>>(
          future: _page,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<MusicServerPage<MusicServerAlbum>> snap,
              ) {
                if (snap.hasError) {
                  return SizedBox(
                    height: height,
                    child: musicBrowseErrorView(context, snap.error!, _retry),
                  );
                }
                final List<MusicServerAlbum>? albums = snap.data?.items
                    .take(_limit)
                    .toList();
                if (albums == null) {
                  return SizedBox(
                    height: height,
                    child: const FushiLoadingView(),
                  );
                }
                return SizedBox(
                  height: height,
                  child: HorizontalDragScrollable(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: albums.length,
                      separatorBuilder: (BuildContext context, int i) =>
                          SizedBox(width: tokens.spacing.gap * 1.5),
                      itemBuilder: (BuildContext context, int i) => SizedBox(
                        width: _cardWidth,
                        child: MusicServerAlbumCard(
                          key: ValueKey<String>(
                            'music-recommend-album-${albums[i].id}',
                          ),
                          browser: widget.browser,
                          album: albums[i],
                        ),
                      ),
                    ),
                  ),
                );
              },
        ),
      ],
    );
  }
}

/// Apple Music 地区选择（分区切换旁的小按钮，点开列出可选地区）。
class _AppleMusicRegionButton extends StatelessWidget {
  const _AppleMusicRegionButton({
    required this.storefront,
    required this.onChanged,
  });

  final String storefront;
  final ValueChanged<String> onChanged;

  Future<void> _open(BuildContext context) async {
    final RenderObject? overlay = Overlay.of(
      context,
    ).context.findRenderObject();
    final RenderObject? button = context.findRenderObject();
    if (overlay is! RenderBox || button is! RenderBox) return;
    final Offset anchor = overlay.globalToLocal(
      button.localToGlobal(button.size.bottomLeft(Offset.zero)),
    );
    final String? v = await showFushiMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(anchor, anchor),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        for (final String sf in kAppleMusicStorefrontChoices)
          FushiPopupMenuItem<String>(
            key: ValueKey<String>('music-apple-music-region-$sf'),
            value: sf,
            label: sf.toUpperCase(),
            selected: sf == storefront,
          ),
      ],
    );
    if (v != null && v != storefront) onChanged(v);
  }

  @override
  Widget build(BuildContext context) => FushiPressScale(
    child: FushiTextButton.icon(
      key: const ValueKey<String>('music-apple-music-region'),
      onPressed: () => unawaited(_open(context)),
      icon: const FushiIcon(FushiIcons.globe, size: 18),
      label: Text('${t.music_sources_region} · ${storefront.toUpperCase()}'),
    ),
  );
}
