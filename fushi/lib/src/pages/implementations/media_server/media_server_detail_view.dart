import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/utils.dart';

/// 剧 / 电影详情：与本地「系列」详情页**同一套布局**（`collection_detail_layout.dart`）
/// ——hero（横版背景 + 2:3 海报卡 + logo / 标题 + 徽标 + 题材 + 续播 + 播放）、
/// 全宽作品资料区、「选集」标题 + 季 tab + hayase 式宽集卡网格。
///
/// 数据分三档：[MediaServerBrowser.itemDetail] 失败就拿清单里那条 best-effort
/// 回退（与 `RemoteVideoDetailFetch` 同款口径）；[MediaServerBrowser.listSeasons]
/// 失败当单季（整部剧一列）；集清单失败显示错误 + 重试。集清单分页（一页 100），
/// 触底追加。
class MediaServerDetailView extends StatefulWidget {
  const MediaServerDetailView({
    required this.session,
    required this.item,
    this.initialSeasonId,
    super.key,
  });

  final MediaServerSession session;

  /// 清单里的那条（Movie 或 Series）；详情取回前先用它画。
  final MediaServerItem item;

  /// 进来时选中的季（从季卡 / 集卡进来时带）；null = 第一季。
  final String? initialSeasonId;

  @override
  State<MediaServerDetailView> createState() => _MediaServerDetailViewState();
}

class _MediaServerDetailViewState extends State<MediaServerDetailView>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();

  late MediaServerItem _detail = widget.item;
  List<MediaServerItem> _seasons = const <MediaServerItem>[];
  String? _seasonId;

  /// 多季时的 tab 控制器（单季 null）；季列表变化时重建。
  TabController? _seasonTabs;

  List<MediaServerItem> _episodes = const <MediaServerItem>[];
  int _nextStartIndex = 0;
  bool _hasMore = false;
  bool _episodesLoading = false;
  bool _episodesLoadingMore = false;
  Object? _episodesError;

  /// 换季 +1；旧季的响应回来时丢掉。
  int _generation = 0;

  MediaServerBrowser get _browser => widget.session.browser;

  bool get _isSeries => widget.item.type == MediaServerItemType.series;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_loadDetail());
    if (_isSeries) unawaited(_loadSeasons());
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _seasonTabs?.removeListener(_onSeasonTabChanged);
    _seasonTabs?.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 400) {
      unawaited(_loadMoreEpisodes());
    }
  }

  Future<void> _loadDetail() async {
    try {
      final MediaServerItem detail = await _browser.itemDetail(widget.item.id);
      if (!mounted) return;
      setState(() => _detail = detail);
    } catch (e) {
      debugPrint('[media-server] item detail failed: $e');
    }
  }

  Future<void> _loadSeasons() async {
    List<MediaServerItem> seasons;
    try {
      seasons = await _browser.listSeasons(widget.item.id);
    } catch (e) {
      debugPrint('[media-server] seasons failed: $e');
      seasons = const <MediaServerItem>[];
    }
    if (!mounted) return;
    String? initial;
    if (seasons.isNotEmpty) {
      final String? wanted = widget.initialSeasonId;
      initial = seasons.any((MediaServerItem s) => s.id == wanted)
          ? wanted
          : seasons.first.id;
    }
    setState(() {
      _seasons = seasons;
      _seasonId = initial;
      _syncSeasonTabs();
    });
    unawaited(_reloadEpisodes());
  }

  /// 季列表 / 选中季变化后让 tab 控制器跟上：季数变了重建（长度是构造期定死的），
  /// 没变只对齐下标。单季不建——tab 条本身也不渲染。
  void _syncSeasonTabs() {
    final int count = _seasons.length;
    final int selected = _seasons.indexWhere(
      (MediaServerItem s) => s.id == _seasonId,
    );
    final int index = selected < 0 ? 0 : selected;
    if (count < 2) {
      _seasonTabs?.removeListener(_onSeasonTabChanged);
      _seasonTabs?.dispose();
      _seasonTabs = null;
      return;
    }
    if (_seasonTabs?.length == count) {
      if (_seasonTabs!.index != index) _seasonTabs!.index = index;
      return;
    }
    _seasonTabs?.removeListener(_onSeasonTabChanged);
    _seasonTabs?.dispose();
    _seasonTabs = TabController(length: count, initialIndex: index, vsync: this)
      ..addListener(_onSeasonTabChanged);
  }

  void _onSeasonTabChanged() {
    final TabController? tabs = _seasonTabs;
    // indexIsChanging 期间是动画中间态；只认落定值，避免滑动过程中反复重拉集。
    if (tabs == null || tabs.indexIsChanging) return;
    if (tabs.index < 0 || tabs.index >= _seasons.length) return;
    _selectSeason(_seasons[tabs.index].id);
  }

  Future<void> _reloadEpisodes() async {
    final int generation = ++_generation;
    setState(() {
      _episodes = const <MediaServerItem>[];
      _nextStartIndex = 0;
      _hasMore = false;
      _episodesLoading = true;
      _episodesLoadingMore = false;
      _episodesError = null;
    });
    try {
      final MediaServerPage page = await _browser.listEpisodes(
        seriesId: widget.item.id,
        seasonId: _seasonId,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _episodes = List<MediaServerItem>.unmodifiable(page.items);
        _nextStartIndex = page.nextStartIndex;
        _hasMore = page.hasMore;
        _episodesLoading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _episodesError = e;
        _episodesLoading = false;
      });
    }
  }

  Future<void> _loadMoreEpisodes() async {
    if (_episodesLoading || _episodesLoadingMore || !_hasMore) return;
    final int generation = _generation;
    setState(() => _episodesLoadingMore = true);
    try {
      final MediaServerPage page = await _browser.listEpisodes(
        seriesId: widget.item.id,
        seasonId: _seasonId,
        startIndex: _nextStartIndex,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _episodes = List<MediaServerItem>.unmodifiable(<MediaServerItem>[
          ..._episodes,
          ...page.items,
        ]);
        _nextStartIndex = page.nextStartIndex;
        _hasMore = page.hasMore;
        _episodesLoadingMore = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      debugPrint('[media-server] more episodes failed: $e');
      setState(() {
        _episodesLoadingMore = false;
        _hasMore = false;
      });
    }
  }

  void _selectSeason(String seasonId) {
    if (seasonId == _seasonId) return;
    setState(() {
      _seasonId = seasonId;
      _syncSeasonTabs();
    });
    unawaited(_reloadEpisodes());
  }

  void _playEpisode(MediaServerItem episode) {
    widget.session.playItem(context, episode, siblings: _episodes);
  }

  /// 续播那一集在当前季**已加载集**里的下标：优先有断点的未看完集，其次第一个
  /// 未看的；都看完 -1。hero 续播行、集卡高亮、「播放」按钮三处同一口径——
  /// 文案说「继续看第 5 集」而按钮播第 1 集就是自相矛盾。
  int get _continueIndex {
    if (_episodes.isEmpty) return -1;
    final int inProgress = _episodes.indexWhere(
      (MediaServerItem e) => !e.played && e.positionMs > 0,
    );
    if (inProgress >= 0) return inProgress;
    return _episodes.indexWhere((MediaServerItem e) => !e.played);
  }

  /// 「播放」：电影直接播；剧播续播那集（都看完就第一集）。
  void _playPrimary() {
    if (!_isSeries) {
      widget.session.playItem(context, _detail);
      return;
    }
    if (_episodes.isEmpty) return;
    final int index = _continueIndex;
    _playEpisode(index >= 0 ? _episodes[index] : _episodes.first);
  }

  /// 徽标行（与本地 `_heroBadgeParts` 同口径）：年份 / 全 N 话（剧）/ ★ 评分 /
  /// 时长（电影）。逐项存在才出。
  List<String> _heroBadgeParts() {
    final List<String> parts = <String>[];
    final int? year = _detail.productionYear;
    if (year != null) parts.add('$year');
    final int? episodeCount = _detail.episodeCount;
    if (_isSeries && episodeCount != null && episodeCount > 0) {
      parts.add(t.collection_hero_total_episodes(count: episodeCount));
    }
    final double? rating = _detail.communityRating;
    if (rating != null && rating > 0) {
      parts.add('★ ${rating.toStringAsFixed(1)}');
    }
    if (!_isSeries) {
      final String duration = formatMediaServerDuration(_detail.durationMs);
      if (duration.isNotEmpty) parts.add(duration);
    }
    return parts;
  }

  /// hero 续播行文案（剧且当前季有未看集才出）。
  String? _continueLabel() {
    if (!_isSeries) return null;
    final int index = _continueIndex;
    if (index < 0) return null;
    final MediaServerItem episode = _episodes[index];
    return '${t.collection_continue_progress(n: index + 1)}  ·  ${episode.name}';
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool canPlay = !_isSeries || _episodes.isNotEmpty;
    final List<String> genres = _detail.genres;
    // 本视图是嵌套 Navigator 里的一条路由：没有 Scaffold 就没有 Material 祖先。
    return Scaffold(
      appBar: AppBar(
        title: Text(
          t.video_work_details,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: CustomScrollView(
        key: PageStorageKey<String>(
          '${widget.session.serverId}-detail-${widget.item.id}',
        ),
        controller: _scrollController,
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: CollectionDetailHero(
              backdrop: mediaServerHeroImage(
                _browser,
                _detail,
                kind: MediaServerImageKind.backdrop,
              ),
              cover: mediaServerCoverImage(_browser, _detail),
              logo: mediaServerHeroImage(
                _browser,
                _detail,
                kind: MediaServerImageKind.logo,
              ),
              title: _detail.name,
              badgeParts: _heroBadgeParts(),
              tagNames: genres.take(6).toList(),
              // 简介放下面的全宽资料区（与本地规范作品路径一致），hero 内不重复。
              continueLabel: _continueLabel(),
              playButtonKey: const ValueKey<String>('media-server-detail-play'),
              onPlay: canPlay ? _playPrimary : null,
            ),
          ),
          SliverToBoxAdapter(
            child: CollectionWorkDetailsSection(
              overview: _detail.overview,
              facts: <(String, String)>[
                if (genres.isNotEmpty)
                  (t.video_work_genres, genres.join(' · ')),
              ],
            ),
          ),
          if (_isSeries) ...<Widget>[
            SliverToBoxAdapter(child: _buildEpisodeSectionHeader(tokens)),
            ..._buildEpisodeSlivers(tokens),
          ],
          SliverSafeArea(
            top: false,
            sliver: SliverToBoxAdapter(
              child: SizedBox(height: tokens.spacing.section),
            ),
          ),
        ],
      ),
    );
  }

  /// 「选集」标题 + 多季时的季 tab 条 + 与集网格之间的间距。
  Widget _buildEpisodeSectionHeader(FushiDesignTokens tokens) {
    final TabController? tabs = _seasonTabs;
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.section),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CollectionSectionTitle(t.video_episode_list),
          if (tabs != null && _seasons.length > 1)
            CollectionSeasonTabBar(
              controller: tabs,
              labels: <String>[
                for (final MediaServerItem season in _seasons)
                  season.seasonNumber != null
                      ? t.collection_group_season(n: season.seasonNumber!)
                      : season.name,
              ],
              tabKeys: <Key>[
                for (final MediaServerItem season in _seasons)
                  ValueKey<String>('media-server-season-${season.id}'),
              ],
            ),
          SizedBox(height: tokens.spacing.rowVertical),
        ],
      ),
    );
  }

  List<Widget> _buildEpisodeSlivers(FushiDesignTokens tokens) {
    if (_episodesLoading && _episodes.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(tokens.spacing.card),
            child: Center(child: adaptiveIndicator(context: context)),
          ),
        ),
      ];
    }
    if (_episodesError != null && _episodes.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: FushiPlaceholderMessage(
            icon: Icons.cloud_off_outlined,
            message: t.media_server_items_load_failed,
            detail: '$_episodesError',
            action: FilledButton.icon(
              key: const ValueKey<String>('media-server-episodes-retry'),
              onPressed: () => unawaited(_reloadEpisodes()),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.retry),
            ),
          ),
        ),
      ];
    }
    if (_episodes.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: FushiPlaceholderMessage(
            icon: Icons.tv_off_outlined,
            message: t.video_episode_list_empty,
          ),
        ),
      ];
    }
    final int continueIndex = _continueIndex;
    return <Widget>[
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
        // 列数按网格**实际**可用宽度算（页边距已扣掉），与本地页同一条规则。
        sliver: SliverLayoutBuilder(
          builder: (BuildContext context, SliverConstraints constraints) {
            const double spacing = 12;
            return SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: collectionEpisodeColumns(
                  constraints.crossAxisExtent,
                ),
                mainAxisExtent: kCollectionEpisodeCardHeight,
                crossAxisSpacing: spacing,
                mainAxisSpacing: spacing,
              ),
              delegate: SliverChildBuilderDelegate(
                (BuildContext context, int index) => _buildEpisodeTile(
                  context,
                  _episodes[index],
                  index,
                  isContinue: index == continueIndex,
                ),
                childCount: _episodes.length,
              ),
            );
          },
        ),
      ),
      if (_episodesLoadingMore)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(tokens.spacing.card),
            child: Center(child: adaptiveIndicator(context: context)),
          ),
        ),
    ];
  }

  /// 一格集卡：[CollectionEpisodeCard] 是纯视觉（整卡 IgnorePointer），点击 /
  /// Enter / 手柄 A 都在这一层接：外层手势 + [Actions] + [FushiFocusTarget]。
  /// 测试与 itest 按 `media-server-episode-<id>` 定位，key 放最外层。
  Widget _buildEpisodeTile(
    BuildContext context,
    MediaServerItem episode,
    int index, {
    required bool isContinue,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ImageProvider? image = mediaServerCoverImage(
      _browser,
      episode,
      kind: episode.hasThumb
          ? MediaServerImageKind.thumb
          : MediaServerImageKind.primary,
    );
    final String duration = formatMediaServerDuration(episode.durationMs);
    final Widget card = CollectionEpisodeCard(
      thumb: collectionEpisodeThumb(context, image),
      number: '${episode.episodeNumber ?? index + 1}',
      title: episode.name,
      summary: episode.overview,
      completed: episode.played,
      positionMs: episode.positionMs,
      isContinue: isContinue,
      trailingStatus: duration.isEmpty
          ? null
          : Text(
              duration,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
    );
    // 卡内是 IgnorePointer，手势层必须 opaque 才能靠自己命中。
    return GestureDetector(
      key: ValueKey<String>('media-server-episode-${episode.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _playEpisode(episode),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Actions(
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                _playEpisode(episode);
                return null;
              },
            ),
          },
          child: FushiFocusTarget(
            id: FushiFocusId(
              '${widget.session.serverId}-episode-${episode.id}',
            ),
            child: card,
          ),
        ),
      ),
    );
  }
}
