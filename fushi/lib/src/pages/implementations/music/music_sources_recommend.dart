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
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 有推荐首页可看的来源：声明了 home 的插件，或任一服务器。
bool musicSourceHasRecommend(MusicOnlineSource s) => switch (s) {
  MusicPluginOnlineSource(:final MusicPluginManifest manifest) => manifest.can(
    MusicPluginCapability.home,
  ),
  MusicServerOnlineSource() => true,
  _ => false,
};

class MusicSourcesRecommendView extends ConsumerStatefulWidget {
  const MusicSourcesRecommendView({
    super.key,
    required this.sources,
    required this.onSourcesChanged,
  });

  /// 已排序、显示中的来源（调用方已按 [musicSourceHasRecommend] 过滤）。
  final List<MusicOnlineSource> sources;

  /// 来源本身变了（如 Apple Music 换地区）：调用方重读来源。
  final VoidCallback onSourcesChanged;

  @override
  ConsumerState<MusicSourcesRecommendView> createState() =>
      _MusicSourcesRecommendViewState();
}

class _MusicSourcesRecommendViewState
    extends ConsumerState<MusicSourcesRecommendView> {
  /// 选中的来源 key；null = 全部。
  String? _selected;

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

  void _select(String? key) => setState(() => _selected = key);

  Future<void> _setStorefront(String sf) async {
    await ref.read(appProvider).prefsRepo.setMusicAppleMusicStorefront(sf);
    widget.onSourcesChanged();
  }

  Widget _chips(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    Widget chip(String? key, String label) => Padding(
      padding: EdgeInsetsDirectional.only(end: tokens.spacing.gap / 2),
      child: FushiPressScale(
        child: FushiChoiceChip(
          key: ValueKey<String>('music-recommend-source-${key ?? 'all'}'),
          label: Text(label),
          selected: _selected == key,
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

  Widget _content(BuildContext context) {
    final MusicOnlineSource? s = _selectedSource;
    return switch (s) {
      MusicPluginOnlineSource(:final MusicPluginManifest manifest) =>
        MusicPluginRecommendView(
          key: ValueKey<String>('music-recommend-${s.key}'),
          sources: <MusicPluginManifest>[manifest],
          showPersonal: false,
        ),
      MusicServerOnlineSource(:final MusicServerBrowser browser) =>
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
      _ => MusicPluginRecommendView(
        key: const ValueKey<String>('music-recommend-all'),
        sources: _plugins,
        trailing: <Widget>[
          for (final MusicOnlineSource o in widget.sources)
            if (o is MusicServerOnlineSource)
              _ServerShelf(
                key: ValueKey<String>('music-recommend-shelf-${o.key}'),
                browser: o.browser,
                onViewAll: () => _select(o.key),
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
        _chips(context),
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
  });

  final MusicServerBrowser browser;
  final VoidCallback onViewAll;

  @override
  State<_ServerShelf> createState() => _ServerShelfState();
}

class _ServerShelfState extends State<_ServerShelf> {
  static const int _limit = 12;
  static const double _cardWidth = 150;

  late Future<MusicServerPage<MusicServerAlbum>> _page = widget.browser
      .listAlbums(offset: 0);

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double height =
        _cardWidth / kShelfAlbumAspectRatio + ShelfCardMeta.heightFor(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        musicRecommendSectionHeader(
          title: widget.browser.displayName,
          actions: <Widget>[
            FushiPressScale(
              child: FushiTextButton(
                key: ValueKey<String>(
                  'music-recommend-view-all-${widget.browser.serverId}',
                ),
                onPressed: widget.onViewAll,
                child: Text(t.music_sources_view_all),
              ),
            ),
          ],
        ),
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
                    child: musicBrowseErrorView(
                      context,
                      snap.error!,
                      () => setState(() {
                        _page = widget.browser.listAlbums(offset: 0);
                      }),
                    ),
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
