import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

/// 剧 / 电影详情（2026-10 重做）：hero 与本地「系列」详情同一套
/// （`collection_detail_layout.dart`：横版背景首帧淡入 + 渐变 + 2:3 海报卡 +
/// logo / 白字标题 + 元信息胶囊 + 续播行 + 主按钮「播放 / 继续」+ 可选次按钮
/// 「下载」）、全宽作品资料区、「选集」标题 + 季胶囊 + 分组集列表（MD3 分段卡 /
/// Apple inset grouped：16:9 缩略 + 集号标题 + 时长 + 进度 + 已看勾）。集列表在
/// 进场窗口里错峰淡入，换季时重开窗口（新一季整列交叉淡入）。
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

class _MediaServerDetailViewState extends State<MediaServerDetailView> {
  final ScrollController _scrollController = ScrollController();

  late MediaServerItem _detail = widget.item;
  List<MediaServerItem> _seasons = const <MediaServerItem>[];
  String? _seasonId;

  List<MediaServerItem> _episodes = const <MediaServerItem>[];
  int _nextStartIndex = 0;
  bool _hasMore = false;
  bool _episodesLoading = false;
  bool _episodesLoadingMore = false;
  Object? _episodesError;

  /// 换季 +1；旧季的响应回来时丢掉。
  int _generation = 0;

  /// 每次一季的第一页落地 +1：集列表进场窗口的 replayKey（换季整列重新错峰
  /// 淡入；追加页不动它）。
  int _episodeEpoch = 0;

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
    });
    unawaited(_reloadEpisodes());
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
        _episodeEpoch += 1;
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
    setState(() => _seasonId = seasonId);
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
      appBar: FushiAppBar(
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
              playLabel: _resumesMidway ? t.video_continue_watching : null,
              playButtonKey: const ValueKey<String>('media-server-detail-play'),
              onPlay: canPlay ? _playPrimary : null,
              secondaryAction: _buildDownloadAction(),
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

  /// 「播放」会从中途接着播（电影有断点 / 剧的续播集有断点）：主按钮改叫「继续
  /// 观看」，与 hero 续播行同一口径。
  bool get _resumesMidway {
    if (!_isSeries) return !_detail.played && _detail.positionMs > 0;
    final int index = _continueIndex;
    return index >= 0 && _episodes[index].positionMs > 0;
  }

  /// hero 次按钮「下载到本机」：只有会话接了下载出口才出（见
  /// [MediaServerSession.download]）。电影下自己；剧下续播那一集，同伴是当前季
  /// 已加载的全部集（与「播放」同一份请求形态，由下载出口决定下一集还是整季）。
  Widget? _buildDownloadAction() {
    final MediaServerDownloadHandler? download = widget.session.download;
    if (download == null) return null;
    final bool ready = !_isSeries || _episodes.isNotEmpty;
    return FushiFilledButton.tonalIcon(
      key: const ValueKey<String>('media-server-detail-download'),
      icon: const FushiIcon(Icons.download_rounded),
      label: Text(t.remote_video_download),
      overImage: true,
      onPressed: !ready
          ? null
          : () {
              if (!_isSeries) {
                download(
                  context,
                  MediaServerPlayRequest(
                    browser: _browser,
                    info: _browser.toRemoteVideoInfo(_detail),
                  ),
                );
                return;
              }
              final int index = _continueIndex < 0 ? 0 : _continueIndex;
              download(
                context,
                MediaServerPlayRequest(
                  browser: _browser,
                  info: _browser.toRemoteVideoInfo(_episodes[index]),
                  members: <RemoteVideoInfo>[
                    for (final MediaServerItem e in _episodes)
                      _browser.toRemoteVideoInfo(e),
                  ],
                  initialIndex: index,
                ),
              );
            },
    );
  }

  String _seasonLabel(MediaServerItem season) => season.seasonNumber != null
      ? t.collection_group_season(n: season.seasonNumber!)
      : season.name;

  /// 「选集」标题 + 多季时的季胶囊行 + 与集列表之间的间距。季胶囊是
  /// [FushiSelectableChip]（MD3 filter chip / Apple 液态玻璃胶囊，选中走强调色），
  /// 可横滑、可 Tab / 方向键逐个聚焦。
  Widget _buildEpisodeSectionHeader(FushiDesignTokens tokens) {
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.section),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CollectionSectionTitle(t.video_episode_list),
          if (_seasons.length > 1)
            Padding(
              key: const ValueKey<String>('collection-season-tabs'),
              padding: EdgeInsets.only(top: tokens.spacing.gap),
              child: HorizontalDragScrollable(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  // 上下各留 4：玻璃胶囊的投影不被横滚区裁掉。
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.page,
                    vertical: 4,
                  ),
                  child: Row(
                    children: <Widget>[
                      for (int i = 0; i < _seasons.length; i++) ...<Widget>[
                        if (i > 0) SizedBox(width: tokens.spacing.gap),
                        FushiSelectableChip(
                          key: ValueKey<String>(
                            'media-server-season-${_seasons[i].id}',
                          ),
                          label: _seasonLabel(_seasons[i]),
                          selected: _seasons[i].id == _seasonId,
                          allowLabelOverflow: true,
                          focusId: FushiFocusId(
                            '${widget.session.serverId}-season-${_seasons[i].id}',
                          ),
                          onSelected: (bool _) => _selectSeason(_seasons[i].id),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
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
            padding: EdgeInsets.all(tokens.spacing.section),
            child: const FushiLoadingView(compact: true),
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
            action: FushiFilledButton.icon(
              key: const ValueKey<String>('media-server-episodes-retry'),
              onPressed: () => unawaited(_reloadEpisodes()),
              icon: const FushiIcon(Icons.refresh_rounded),
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
    final int count = _episodes.length;
    final bool wide = MediaQuery.sizeOf(context).width >= 720;
    return <Widget>[
      // 集列表限宽：一行一集，桌面 1600 宽拉满时缩略图旁全是空白。
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
        sliver: SliverConstrainedCrossAxis(
          maxExtent: 980,
          sliver: FushiEntranceScope(
            replayKey: _episodeEpoch,
            child: SliverList.builder(
              itemCount: count,
              itemBuilder: fushiStaggeredItemBuilder(
                (BuildContext context, int index) => _buildEpisodeRow(
                  _episodes[index],
                  index,
                  count: count,
                  wide: wide,
                  isContinue: index == continueIndex,
                ),
              ),
            ),
          ),
        ),
      ),
      if (_episodesLoadingMore)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(tokens.spacing.card),
            child: const FushiLoadingView(compact: true),
          ),
        ),
    ];
  }

  /// 一集一行（分组列表的一格）：整行可点 / Enter / 手柄 A 播放，焦点目标与
  /// 点击都由行外壳（[FushiGroupedListItem] → FushiCard）接。测试与 itest 按
  /// `media-server-episode-<id>` 定位，key 放行外壳上。
  Widget _buildEpisodeRow(
    MediaServerItem episode,
    int index, {
    required int count,
    required bool wide,
    required bool isContinue,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double thumbWidth = wide ? 168 : 128;
    final double rowPad = tokens.spacing.rowHorizontal;
    return FushiGroupedListItem(
      key: ValueKey<String>('media-server-episode-${episode.id}'),
      index: index,
      count: count,
      // Apple 分隔线从文字起点开始（行内边距 + 缩略图 + 间距）。
      separatorIndent: rowPad + thumbWidth + rowPad,
      focusId: FushiFocusId('${widget.session.serverId}-episode-${episode.id}'),
      onTap: () => _playEpisode(episode),
      child: _MediaServerEpisodeRow(
        image: mediaServerCoverImage(
          _browser,
          episode,
          kind: episode.hasThumb
              ? MediaServerImageKind.thumb
              : MediaServerImageKind.primary,
        ),
        episode: episode,
        number: episode.episodeNumber ?? index + 1,
        thumbWidth: thumbWidth,
        showSummary: wide,
        isContinue: isContinue,
      ),
    );
  }
}

/// 集列表一行的内容：16:9 缩略图（封面框 + 进度胶囊 + 已看勾）+「N. 集名」+
/// 时长 / 看到哪 + 宽屏两行简介 + 行尾状态（续播那集强调色播放钮）。纯视觉，
/// 交互归行外壳。
class _MediaServerEpisodeRow extends StatelessWidget {
  const _MediaServerEpisodeRow({
    required this.image,
    required this.episode,
    required this.number,
    required this.thumbWidth,
    required this.showSummary,
    required this.isContinue,
  });

  final ImageProvider? image;
  final MediaServerItem episode;
  final int number;
  final double thumbWidth;
  final bool showSummary;
  final bool isContinue;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final FushiAppleColors appleColors = appleColorsOf(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color secondary = apple
        ? appleColors.secondaryLabel
        : tokens.surfaces.onVariant;
    final Color accent = apple ? appleColors.accent : cs.primary;
    final double? progress = episode.played
        ? null
        : mediaServerProgress(episode);
    final String duration = formatMediaServerDuration(episode.durationMs);
    final List<String> meta = <String>[
      if (episode.positionMs > 0 && !episode.played)
        t.video_watched_up_to(
          time: formatMediaServerDuration(episode.positionMs),
        )
      else if (duration.isNotEmpty)
        duration,
    ];
    final String? summary = episode.overview?.trim();
    final ImageProvider? image = this.image;
    final double rowPad = tokens.spacing.rowHorizontal;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: rowPad, vertical: 10),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: thumbWidth,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ShelfCoverFrame(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (image == null)
                      const ShelfCoverPlaceholder(
                        icon: Icons.movie_outlined,
                        iconSize: 24,
                      )
                    else
                      PortraitCoverImage(
                        image: image,
                        landscapeSlot: true,
                        errorBuilder: (_) => const ShelfCoverPlaceholder(
                          icon: Icons.movie_outlined,
                          iconSize: 24,
                        ),
                      ),
                    if (episode.played)
                      const Positioned(
                        top: 4,
                        right: 4,
                        child: CoverBadge(icon: Icons.check_rounded),
                      ),
                    if (progress != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: CoverProgressStrip(value: progress),
                      ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(width: rowPad),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '$number. ${episode.name}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle.copyWith(
                    fontWeight: apple ? FontWeight.w600 : FontWeight.w500,
                    color: episode.played && !isContinue ? secondary : null,
                  ),
                ),
                if (meta.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata.copyWith(color: secondary),
                  ),
                ],
                if (showSummary &&
                    summary != null &&
                    summary.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata.copyWith(
                      color: secondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          // 行尾状态：续播那集是强调色播放钮（与 hero「继续看第 N 集」同一集），
          // 看完的是次要色对勾，其余留空。
          SizedBox(
            width: 28,
            child: isContinue
                ? FushiIcon(
                    Icons.play_circle_fill_rounded,
                    key: const ValueKey<String>(
                      'media-server-episode-continue',
                    ),
                    color: accent,
                    size: 26,
                  )
                : episode.played
                ? FushiIcon(
                    Icons.check_circle_outline_rounded,
                    color: secondary,
                    size: 20,
                  )
                : null,
          ),
        ],
      ),
    );
  }
}
