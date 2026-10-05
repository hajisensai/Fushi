import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

/// 剧 / 电影详情（2026-10 M3E 重做）：hero 与本地「系列」详情同一套
/// （`collection_detail_layout.dart`：fanart / 封面模糊 + 色晕 scrim 大背景、2:3
/// 封面卡、logo / Display 标题、元信息 chip、续播行、主操作按钮组「播放 / 继续」+
/// tonal「下载」、可展开简介），宽屏两栏（左 hero sticky、右选集，
/// [MediaDetailLayout]），「选集」标题 + 浮动胶囊季分段 + 分段列表（16:9 缩略 +
/// 集号胶囊 + 集名 + 时长 + primary 进度 + tertiary 已看勾，续播集 primaryContainer
/// 高亮）。集列表在进场窗口里错峰淡入，换季时重开窗口。
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
    with TickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();

  /// 季分段控制器：只在 ≥2 季时存在（季清单回来后建一次）。
  TabController? _seasonTabs;

  late MediaServerItem _detail = widget.item;

  /// 当前选中的版本在 [MediaServerItem.versions] 里的下标（详情回来后按记住的
  /// 选择解析；单版本 / 无版本 -1，版本区不显示）。
  int _versionIndex = -1;
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
      setState(() {
        _detail = detail;
        _versionIndex = detail.versions.length > 1
            ? resolveMediaServerVersionIndex(
                serverId: _browser.serverId,
                itemId: detail.id,
                seriesId: detail.seriesId,
                versions: detail.versions,
              )
            : -1;
      });
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
    _seasonTabs?.dispose();
    _seasonTabs = seasons.length > 1
        ? (TabController(
            length: seasons.length,
            initialIndex: seasons
                .indexWhere((MediaServerItem s) => s.id == initial)
                .clamp(0, seasons.length - 1),
            vsync: this,
          )..addListener(_onSeasonTabChanged))
        : null;
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

  /// 选版本：记住（本条目 + 同剧），「播放」/ 下载取流时按它带 MediaSourceId。
  void _selectVersion(int index) {
    if (index == _versionIndex) return;
    rememberMediaServerVersion(
      serverId: _browser.serverId,
      itemId: _detail.id,
      seriesId: _detail.seriesId,
      version: _detail.versions[index],
    );
    setState(() => _versionIndex = index);
  }

  /// 季分段落定（点按 / Enter / 横滑）→ 换季重拉集清单。动画中间态不算。
  void _onSeasonTabChanged() {
    final TabController? tabs = _seasonTabs;
    if (tabs == null || tabs.indexIsChanging) return;
    if (tabs.index < 0 || tabs.index >= _seasons.length) return;
    _selectSeason(_seasons[tabs.index].id);
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

  /// 元信息 chip（与本地 `_heroChips` 同口径）：年份 / 全 N 话（剧）/ ★ 评分 /
  /// 时长（电影）。逐项存在才出。
  List<MediaDetailChip> _heroChips() {
    final int? year = _detail.productionYear;
    final int? episodeCount = _detail.episodeCount;
    final double? rating = _detail.communityRating;
    final String duration = _isSeries
        ? ''
        : formatMediaServerDuration(_detail.durationMs);
    return <MediaDetailChip>[
      if (year != null) MediaDetailChip('$year', icon: FushiIcons.calendar),
      if (_isSeries && episodeCount != null && episodeCount > 0)
        MediaDetailChip(
          t.collection_hero_total_episodes(count: episodeCount),
          icon: FushiIcons.video,
        ),
      if (rating != null && rating > 0)
        MediaDetailChip(
          '★ ${rating.toStringAsFixed(1)}',
          tone: MediaDetailChipTone.primary,
        ),
      if (duration.isNotEmpty)
        MediaDetailChip(duration, icon: FushiIcons.timer),
    ];
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
    final ImageProvider? backdrop = mediaServerHeroImage(
      _browser,
      _detail,
      kind: MediaServerImageKind.backdrop,
    );
    final ImageProvider? cover = mediaServerCoverImage(_browser, _detail);
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
      // M3E 详情布局：宽屏两栏（左 hero sticky、右版本 / 选集 / 资料），窄屏单列。
      // 滚动控制器挂在正文（两栏时右栏）上：触底分页追加集清单。
      body: MediaDetailLayout(
        controller: _scrollController,
        backdrop: collectionHeroBackdropImage(backdrop: backdrop, cover: cover),
        backdropBlur: collectionHeroBackdropBlur(backdrop: backdrop),
        bottomPadding: tokens.spacing.section,
        header: CollectionDetailHero(
          backdrop: backdrop,
          cover: cover,
          logo: mediaServerHeroImage(
            _browser,
            _detail,
            kind: MediaServerImageKind.logo,
          ),
          title: _detail.name,
          chips: _heroChips(),
          tagNames: genres.take(6).toList(),
          summary: _detail.overview,
          continueLabel: _continueLabel(),
          playLabel: _resumesMidway ? t.video_continue_watching : null,
          playButtonKey: const ValueKey<String>('media-server-detail-play'),
          onPlay: canPlay ? _playPrimary : null,
          secondaryAction: _buildDownloadAction(),
        ),
        slivers: <Widget>[
          if (_isSeries) ...<Widget>[
            SliverToBoxAdapter(child: _buildEpisodeSectionHeader(tokens)),
            ..._buildEpisodeSlivers(tokens),
          ],
          if (_versionIndex >= 0)
            SliverToBoxAdapter(
              child: MediaServerVersionSection(
                versions: _detail.versions,
                selectedIndex: _versionIndex,
                focusPrefix: '${widget.session.serverId}-version-${_detail.id}',
                onSelected: _selectVersion,
              ),
            ),
          // 简介已在 hero 里（可展开）；这里只留事实行。
          SliverToBoxAdapter(
            child: CollectionWorkDetailsSection(
              overview: _detail.overview,
              showOverview: false,
              facts: <(String, String)>[
                if (genres.isNotEmpty)
                  (t.video_work_genres, genres.join(' · ')),
              ],
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
    return MediaDetailSecondaryButton(
      buttonKey: const ValueKey<String>('media-server-detail-download'),
      icon: FushiIcons.download,
      label: t.remote_video_download,
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

  /// 「选集」标题（计数胶囊）+ 多季时的季分段（与本地系列详情同一枚浮动胶囊，
  /// [CollectionSeasonTabBar]：Tab / 方向键逐个聚焦、Enter 选中、可横滑）。
  Widget _buildEpisodeSectionHeader(FushiDesignTokens tokens) {
    final TabController? seasonTabs = _seasonTabs;
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.section),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CollectionSectionTitle(
            t.video_episode_list,
            count: _episodes.isEmpty ? null : _episodes.length,
          ),
          if (seasonTabs != null && _seasons.length > 1)
            CollectionSeasonTabBar(
              controller: seasonTabs,
              labels: <String>[
                for (final MediaServerItem season in _seasons)
                  _seasonLabel(season),
              ],
              tabKeys: <Key>[
                for (final MediaServerItem season in _seasons)
                  ValueKey<String>('media-server-season-${season.id}'),
              ],
            ),
          SizedBox(height: tokens.spacing.card),
        ],
      ),
    );
  }

  List<Widget> _buildEpisodeSlivers(FushiDesignTokens tokens) {
    if (_episodesLoading && _episodes.isEmpty) {
      return <Widget>[
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
          sliver: SliverConstrainedCrossAxis(
            maxExtent: 980,
            sliver: SliverToBoxAdapter(
              child: FushiSkeletonShimmer(
                child: Column(
                  children: <Widget>[
                    for (int i = 0; i < 4; i++) ...<Widget>[
                      FushiSkeleton(
                        height: 88,
                        borderRadius: fushiGroupedItemRadius(context, i, 4),
                      ),
                      const SizedBox(height: 2),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ];
    }
    if (_episodesError != null && _episodes.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.cloudOff,
            tone: FushiPlaceholderTone.error,
            message: t.media_server_items_load_failed,
            detail: '$_episodesError',
            action: FushiFilledButton.icon(
              key: const ValueKey<String>('media-server-episodes-retry'),
              onPressed: () => unawaited(_reloadEpisodes()),
              icon: const FushiIcon(FushiIcons.refresh),
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
            icon: FushiIcons.video,
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

  /// 一集一行（M3E 分段列表的一格，[MediaDetailItemRow]）：整行可点 / Enter /
  /// 手柄 A 播放，焦点目标与点击都由行外壳接。测试与 itest 按
  /// `media-server-episode-<id>` 定位，key 放行外壳上。
  Widget _buildEpisodeRow(
    MediaServerItem episode,
    int index, {
    required int count,
    required bool wide,
    required bool isContinue,
  }) {
    final double? progress = episode.played
        ? null
        : mediaServerProgress(episode);
    final String duration = formatMediaServerDuration(episode.durationMs);
    final String? summary = episode.overview?.trim();
    return MediaDetailItemRow(
      key: ValueKey<String>('media-server-episode-${episode.id}'),
      index: index,
      count: count,
      title: episode.name,
      subtitle: wide && summary != null && summary.isNotEmpty ? summary : null,
      meta: <String>[
        if (episode.positionMs > 0 && !episode.played)
          t.video_watched_up_to(
            time: formatMediaServerDuration(episode.positionMs),
          )
        else if (duration.isNotEmpty)
          duration,
      ],
      progress: progress,
      completed: episode.played,
      current: isContinue,
      focusId: FushiFocusId('${widget.session.serverId}-episode-${episode.id}'),
      onTap: () => _playEpisode(episode),
      leading: _MediaServerEpisodeThumb(
        image: mediaServerCoverImage(
          _browser,
          episode,
          kind: episode.hasThumb
              ? MediaServerImageKind.thumb
              : MediaServerImageKind.primary,
        ),
        number: '${episode.episodeNumber ?? index + 1}',
        width: wide ? 168 : 128,
        current: isContinue,
      ),
    );
  }
}

/// 集列表行首的 16:9 缩略图：封面框 + 左上角集号胶囊（续播那集 primary 实色）。
class _MediaServerEpisodeThumb extends StatelessWidget {
  const _MediaServerEpisodeThumb({
    required this.image,
    required this.number,
    required this.width,
    required this.current,
  });

  final ImageProvider? image;
  final String number;
  final double width;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = this.image;
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ShelfCoverFrame(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (image == null)
                const ShelfCoverPlaceholder(
                  icon: FushiIcons.video,
                  iconSize: 24,
                )
              else
                PortraitCoverImage(
                  image: image,
                  landscapeSlot: true,
                  errorBuilder: (_) => const ShelfCoverPlaceholder(
                    icon: FushiIcons.video,
                    iconSize: 24,
                  ),
                ),
              PositionedDirectional(
                start: 4,
                top: 4,
                child: CollectionEpisodeNumberPill(
                  number: number,
                  current: current,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「版本」区（多版本电影 / 集的详情页）：版本胶囊行（[FushiSelectableChip]：
/// MD3 filter chip / Apple 液态玻璃胶囊，可 Tab / 方向键逐个聚焦、Enter 选中）
/// + 选中版本的规格行与音轨 / 字幕轨清单。换版本时规格块交叉淡入
/// （[fushiMotionDuration]，墨水屏与「减弱动态效果」下瞬切）。
class MediaServerVersionSection extends StatelessWidget {
  const MediaServerVersionSection({
    required this.versions,
    required this.selectedIndex,
    required this.focusPrefix,
    required this.onSelected,
    super.key,
  });

  final List<MediaServerVersion> versions;
  final int selectedIndex;
  final String focusPrefix;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final Color secondary = apple
        ? appleColorsOf(context).secondaryLabel
        : tokens.surfaces.onVariant;
    final MediaServerVersion selected = versions[selectedIndex];
    return Padding(
      key: const ValueKey<String>('media-server-versions'),
      padding: EdgeInsets.only(top: tokens.spacing.section),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CollectionSectionTitle(t.media_server_versions),
          SizedBox(height: tokens.spacing.gap),
          HorizontalDragScrollable(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // 上下各留 4：玻璃胶囊的投影不被横滚区裁掉。
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.page,
                vertical: 4,
              ),
              child: Row(
                children: <Widget>[
                  for (int i = 0; i < versions.length; i++) ...<Widget>[
                    if (i > 0) SizedBox(width: tokens.spacing.gap),
                    FushiSelectableChip(
                      key: ValueKey<String>(
                        'media-server-version-${versions[i].id}',
                      ),
                      label: versions[i].title,
                      selected: i == selectedIndex,
                      allowLabelOverflow: true,
                      focusId: FushiFocusId('$focusPrefix-${versions[i].id}'),
                      onSelected: (bool _) => onSelected(i),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              0,
            ),
            child: AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.short),
              layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
                alignment: Alignment.topLeft,
                children: <Widget>[...previous, ?current],
              ),
              child: Column(
                key: ValueKey<String>(
                  'media-server-version-info-${selected.id}',
                ),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (selected.qualitySummary.isNotEmpty)
                    Text(
                      selected.qualitySummary,
                      style: tokens.type.listTitle.copyWith(
                        fontWeight: apple ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  if (selected.audioTracks.isNotEmpty)
                    _trackLine(
                      tokens,
                      secondary,
                      t.video_audio_track,
                      selected.audioTracks,
                    ),
                  if (selected.subtitleTracks.isNotEmpty)
                    _trackLine(
                      tokens,
                      secondary,
                      t.section_video_subtitles,
                      selected.subtitleTracks,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _trackLine(
    FushiDesignTokens tokens,
    Color color,
    String label,
    List<MediaServerStreamTrack> tracks,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        '$label: ${tracks.map((MediaServerStreamTrack s) => s.label).where((String l) => l.isNotEmpty).join(' / ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: tokens.type.metadata.copyWith(color: color),
      ),
    );
  }
}
