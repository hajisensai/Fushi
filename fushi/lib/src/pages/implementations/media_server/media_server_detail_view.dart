import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_session.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_widgets.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeInset, FushiFloatingChromeScope;
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

/// 剧 / 电影详情（2026-10 M3E 重做）：hero 与本地「系列」详情同一套
/// （`collection_detail_layout.dart`：fanart / 封面模糊 + 色晕 scrim 大背景、2:3
/// 封面卡、logo / Display 标题、元信息 chip、续播行、主操作按钮组「播放 / 继续」+
/// tonal「下载」「加入 / 移出媒体库」、可展开简介），宽屏两栏（左 hero sticky、右
/// 选集，[MediaDetailLayout]），「选集」标题 + 浮动胶囊季分段 + 与本地系列详情同一
/// 张 hayase 式宽集卡（[CollectionEpisodeCard]：16:9 缩略 + 集号胶囊 + 集名 / 简介 /
/// 时长 + 观看进度，续播集整卡高亮；宽屏两列。2026-10-23 由分段列表行改来，两处
/// 选集排版一致）。集卡在进场窗口里错峰淡入，换季时重开窗口。
///
/// 「加入媒体库」（[MediaServerSession.library]，与在线视频源作品页同一形态）：电影
/// 一行、剧把全部季的集各落一行流媒体书并归进剧名合集，之后从本地媒体库直接点开
/// 播放（起播时按设置里同一台服务器的配置现建客户端，见 `media_server_library.dart`）。
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

  /// 「版本」区展示的那条可播叶子（BUG-3329）：电影 = 自身详情；剧 = 当前季续播
  /// 那一集的详情——选中按「本集 + 同剧」记住，其余集取流时按同名 / 同规格版本
  /// 跟上（[resolveMediaServerVersionIndex]），与 Emby 网页端在集上选版本同一效果。
  /// 清单不带 MediaSources（BUG-1891），所以剧要单独取这一集的详情。
  MediaServerItem? _versionItem;

  /// 当前选中的版本在 [_versionItem] 的 [MediaServerItem.versions] 里的下标
  /// （按记住的选择解析；单版本 / 无版本 -1，版本区不显示）。
  int _versionIndex = -1;
  List<MediaServerItem> _seasons = const <MediaServerItem>[];
  String? _seasonId;

  List<MediaServerItem> _episodes = const <MediaServerItem>[];
  int _nextStartIndex = 0;
  bool _hasMore = false;
  bool _episodesLoading = false;
  bool _episodesLoadingMore = false;
  Object? _episodesError;

  /// 本作品的入库状态（[MediaServerSession.library] 为 null 时恒 null）。
  MediaServerWorkLibraryStatus? _libraryStatus;
  bool _libraryBusy = false;

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
    unawaited(_reloadLibraryState());
    // 从滚到半截的网格点进来：库页浮动工具区回到展开态（新页面从顶部开始），
    // 与 [MediaServerPageFrame] 每层路由成为栈顶时同一口径。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FushiFloatingChromeScope.peek(context)?.resetToTop();
    });
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
        if (!_isSeries) _showVersionsOf(detail);
      });
    } catch (e) {
      debugPrint('[media-server] item detail failed: $e');
    }
  }

  /// 版本区换成 [item] 的版本（只在 setState 里调）。
  void _showVersionsOf(MediaServerItem? item) {
    _versionItem = item;
    _versionIndex = item != null && item.versions.length > 1
        ? resolveMediaServerVersionIndex(
            serverId: _browser.serverId,
            itemId: item.id,
            seriesId: item.seriesId,
            versions: item.versions,
          )
        : -1;
  }

  /// 剧：取当前季续播那一集（都看完取第一集）的详情，拿它的版本表给版本区。
  /// 换季后旧季的响应丢掉；失败就不显示版本区（播放页画质菜单里照样能换）。
  Future<void> _loadEpisodeVersions(int generation) async {
    if (_episodes.isEmpty) return;
    final int index = _continueIndex;
    final MediaServerItem episode = _episodes[index >= 0 ? index : 0];
    try {
      final MediaServerItem detail = await _browser.itemDetail(episode.id);
      if (!mounted || generation != _generation) return;
      setState(() => _showVersionsOf(detail));
    } catch (e) {
      debugPrint('[media-server] episode versions failed: $e');
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
      _showVersionsOf(null);
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
      unawaited(_loadEpisodeVersions(generation));
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

  /// 入库状态只决定按钮是「加入」还是「移出」：读不到时页面照常可用，记日志。
  Future<void> _reloadLibraryState() async {
    final MediaServerVideoLibrary? library = widget.session.library;
    if (library == null) return;
    final MediaServerWorkLibraryStatus status;
    try {
      status = await library.statusOf(_browser, widget.item);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MediaServerDetailView.libraryState',
        error,
        stack,
      );
      return;
    }
    if (mounted) setState(() => _libraryStatus = status);
  }

  bool get _inLibrary => _libraryStatus?.inLibrary ?? false;

  /// 「加入媒体库」：没入过库，或剧在库里但当前季已加载的集里有还没入库的（服务器
  /// 上新出的集）——再点一次只补新集。入库是一次快照，不自动跟服务器上的新集。
  /// 状态没读出来前也显示。
  bool get _canAddToLibrary {
    final MediaServerWorkLibraryStatus? status = _libraryStatus;
    if (status == null || !status.inLibrary) return true;
    return _isSeries &&
        _episodes.any((MediaServerItem e) => !status.online.contains(e.id));
  }

  Future<void> _addToLibrary() async {
    final MediaServerVideoLibrary? library = widget.session.library;
    if (library == null || _libraryBusy) return;
    setState(() => _libraryBusy = true);
    try {
      final int added = await library.addToLibrary(_browser, _detail);
      FushiToast.show(
        msg: t.video_online_library_added(n: added),
        severity: ToastSeverity.success,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MediaServerDetailView.add', error, stack);
      FushiToast.show(msg: '$error', severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _libraryBusy = false);
    }
    await _reloadLibraryState();
  }

  /// 「移出媒体库」：删本作品的流媒体行；已下载到本机的集是普通本地视频，不动。
  Future<void> _removeFromLibrary() async {
    final MediaServerVideoLibrary? library = widget.session.library;
    if (library == null || _libraryBusy) return;
    setState(() => _libraryBusy = true);
    try {
      if (await library.removeFromLibrary(_browser, _detail) > 0) {
        FushiToast.show(msg: t.video_online_library_removed);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MediaServerDetailView.remove',
        error,
        stack,
      );
      FushiToast.show(msg: '$error', severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _libraryBusy = false);
    }
    await _reloadLibraryState();
  }

  /// 选版本：记住（本条目 + 同剧），「播放」/ 下载取流时按它带 MediaSourceId。
  void _selectVersion(int index) {
    final MediaServerItem? item = _versionItem;
    if (item == null || index == _versionIndex) return;
    rememberMediaServerVersion(
      serverId: _browser.serverId,
      itemId: item.id,
      seriesId: item.seriesId,
      version: item.versions[index],
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

  Future<void> _playEpisode(MediaServerItem episode) async {
    await widget.session.playItem(context, episode, siblings: _episodes);
    // 播放页退回来：服务器上的断点 / 已看标记变了，原地重拉（BUG-3491）。
    if (mounted) await _refreshEpisodesInPlace();
  }

  /// 原地重拉当前季**已加载的那些集**（不清空、不出加载态、不动滚动位置）：
  /// 看完一集返回后集卡的「看到 / 已看 / 进度条」与续播高亮跟上服务器。失败就
  /// 保持旧列表（下次进页或换季会重拉）。
  Future<void> _refreshEpisodesInPlace() async {
    if (!_isSeries || _episodesLoading || _episodes.isEmpty) return;
    final int generation = _generation;
    try {
      final MediaServerPage page = await _browser.listEpisodes(
        seriesId: widget.item.id,
        seasonId: _seasonId,
        limit: _episodes.length > kMediaServerEpisodePageSize
            ? _episodes.length
            : kMediaServerEpisodePageSize,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _episodes = List<MediaServerItem>.unmodifiable(page.items);
        _nextStartIndex = page.nextStartIndex;
        _hasMore = page.hasMore;
      });
    } catch (e) {
      debugPrint('[media-server] refresh episodes failed: $e');
    }
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
      unawaited(
        widget.session.playItem(context, _detail).then((_) {
          // 电影：退回来重取详情，断点 / 已看跟上服务器（BUG-3491）。
          if (mounted) unawaited(_loadDetail());
        }),
      );
      return;
    }
    if (_episodes.isEmpty) return;
    final int index = _continueIndex;
    unawaited(_playEpisode(index >= 0 ? _episodes[index] : _episodes.first));
  }

  /// 元信息 chip（与本地 `_heroChips` 同口径）：年份 / 全 N 话（剧）/ ★ 评分 /
  /// 时长（电影）。逐项存在才出。
  List<MediaDetailChip> _heroChips() {
    final int? year = _detail.productionYear;
    final int? episodeCount = _detail.episodeCount;
    final double? rating = _detail.communityRating;
    final int? unplayed = _detail.unplayedChildCount;
    final String duration = _isSeries
        ? ''
        : formatMediaServerDuration(_detail.durationMs);
    return <MediaDetailChip>[
      if (_inLibrary)
        MediaDetailChip(
          t.video_discovery_in_library,
          icon: FushiIcons.libraryAdd,
          tone: MediaDetailChipTone.secondary,
        ),
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
      // 观看进度（与本地系列详情的「已看完 x/N」同口径）：服务器给出总集数与未看
      // 集数时才出。
      if (_isSeries &&
          episodeCount != null &&
          episodeCount > 0 &&
          unplayed != null)
        MediaDetailChip(
          t.collection_watched_progress(
            done: (episodeCount - unplayed).clamp(0, episodeCount),
            total: episodeCount,
          ),
          icon: FushiIcons.success,
          tone: unplayed <= 0
              ? MediaDetailChipTone.tertiary
              : MediaDetailChipTone.neutral,
        ),
    ];
  }

  /// hero 续播行文案（剧且当前季有未看集才出）。
  /// 主操作会播的那一集的名字（电影 / 还没取到集为 null）。
  String? _resumeEpisodeName() {
    if (!_isSeries || _episodes.isEmpty) return null;
    final int index = _continueIndex;
    return (index >= 0 ? _episodes[index] : _episodes.first).name;
  }

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
    // 本路由若直接叠在库页浮动工具区底下（外壳不整体下移本分区时），把工具区
    // 高度并进顶部安全区：顶栏胶囊排在页签下方，fanart 背景仍从窗口顶端铺起，
    // [MediaDetailLayout] 照常按 MediaQuery 顶部 padding 让位。外壳整体下移时
    // 这里为 0，不改任何东西。
    final double chromeInset = FushiFloatingChromeInset.of(context);
    final MediaQueryData media = MediaQuery.of(context);
    // 本视图是嵌套 Navigator 里的一条路由：没有 Scaffold 就没有 Material 祖先。
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(top: media.padding.top + chromeInset),
        viewPadding: media.viewPadding.copyWith(
          top: media.viewPadding.top + chromeInset,
        ),
      ),
      // 让位已并进 MediaQuery，子树不再重复让。
      child: FushiFloatingChromeInset(
        top: 0,
        child: Scaffold(
          // 背景铺满到窗口顶端，浮动顶栏只是几颗胶囊（不画整宽底带）；让位由
          // [MediaDetailLayout] 按 MediaQuery 顶部 padding 自己处理。
          extendBodyBehindAppBar: true,
          appBar: FushiAppBar(
            title: Text(
              t.video_work_details,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            surfaceTintColor: Colors.transparent,
            elevation: 0,
          ),
          // M3E 详情布局：宽屏两栏（左 hero sticky、右版本 / 选集 / 资料），窄屏单列。
          // 滚动控制器挂在正文（两栏时右栏）上：触底分页追加集清单。
          body: MediaDetailLayout(
            controller: _scrollController,
            backdrop: collectionHeroBackdropImage(
              backdrop: backdrop,
              cover: cover,
            ),
            backdropBlur: collectionHeroBackdropBlur(backdrop: backdrop),
            bottomPadding: tokens.spacing.section,
            // 「继续 / 开始观看」悬浮按钮：与 hero 主按钮同一动作（剧 = 续播那一集）。
            fab: canPlay
                ? MediaDetailResumeFab(
                    buttonKey: const ValueKey<String>(
                      'media-server-detail-resume-fab',
                    ),
                    watching: true,
                    started: _resumesMidway,
                    itemLabel: _resumeEpisodeName(),
                    onPressed: _playPrimary,
                  )
                : null,
            header: CollectionDetailHero(
              backdrop: backdrop,
              cover: cover,
              coverMaterial: ShelfCoverMaterial.glossyPoster,
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
              playLabel: MediaDetailResumeFab.labelFor(
                watching: true,
                started: _resumesMidway,
              ),
              playButtonKey: const ValueKey<String>('media-server-detail-play'),
              onPlay: canPlay ? _playPrimary : null,
              secondaryActions: <Widget>[
                ?_buildDownloadAction(),
                ..._buildLibraryActions(),
              ],
            ),
            slivers: <Widget>[
              // 版本在选集之上：剧的集清单可能很长（分页触底追加），放在后面就沉底看不见。
              if (_versionItem case final MediaServerItem versionItem
                  when _versionIndex >= 0)
                SliverToBoxAdapter(
                  child: MediaServerVersionSection(
                    versions: versionItem.versions,
                    selectedIndex: _versionIndex,
                    focusPrefix:
                        '${widget.session.serverId}-version-${versionItem.id}',
                    onSelected: _selectVersion,
                  ),
                ),
              if (_isSeries) ...<Widget>[
                SliverToBoxAdapter(child: _buildEpisodeSectionHeader(tokens)),
                ..._buildEpisodeSlivers(tokens),
              ],
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
        ),
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

  /// hero 次按钮「加入 / 移出媒体库」：只有会话接了本地库才出（见
  /// [MediaServerSession.library]）。剧在集清单回来前「加入」禁用（与「播放」同门）。
  List<Widget> _buildLibraryActions() {
    if (widget.session.library == null) return const <Widget>[];
    final bool ready = !_isSeries || _episodes.isNotEmpty;
    return <Widget>[
      if (_canAddToLibrary)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('media-server-detail-library-add'),
          icon: FushiIcons.libraryAdd,
          label: t.video_online_library_add,
          busy: _libraryBusy,
          onPressed: !ready ? null : () => unawaited(_addToLibrary()),
        ),
      if (_inLibrary)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>(
            'media-server-detail-library-remove',
          ),
          icon: FushiIcons.libraryAdd,
          label: t.video_online_library_remove,
          busy: _libraryBusy,
          onPressed: () => unawaited(_removeFromLibrary()),
        ),
    ];
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
          sliver: SliverToBoxAdapter(
            child: FushiSkeletonShimmer(
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < 3; i++) ...<Widget>[
                    FushiSkeleton(
                      height: kCollectionEpisodeCardHeight,
                      borderRadius: FushiM3eShape.cardRadius,
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
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
    const double spacing = 12;
    return <Widget>[
      // 与本地系列详情同一套网格几何（[collectionEpisodeColumns] /
      // [kCollectionEpisodeCardHeight]）：宽屏两列、否则一列，卡高固定。
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
        sliver: SliverLayoutBuilder(
          builder: (BuildContext context, SliverConstraints constraints) {
            final double width = constraints.crossAxisExtent;
            final int columns = collectionEpisodeColumns(width);
            final double columnWidth =
                (width - spacing * (columns - 1)) / columns;
            return FushiEntranceScope(
              replayKey: _episodeEpoch,
              child: SliverGrid.builder(
                itemCount: count,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  childAspectRatio: columnWidth / kCollectionEpisodeCardHeight,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
                ),
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int index) => _buildEpisodeCard(
                    context,
                    _episodes[index],
                    index,
                    isContinue: index == continueIndex,
                  ),
                ),
              ),
            );
          },
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

  /// 一集一张卡（与本地系列详情同一张 [CollectionEpisodeCard]）：整卡可点 / Enter /
  /// 手柄 A 播放。卡本身是纯视觉（IgnorePointer），点击由外层墨水接、焦点由
  /// [FushiFocusTarget] 接。测试与 itest 按 `media-server-episode-<id>` 定位，key
  /// 放在最外层。
  Widget _buildEpisodeCard(
    BuildContext context,
    MediaServerItem episode,
    int index, {
    required bool isContinue,
  }) {
    final String duration = formatMediaServerDuration(episode.durationMs);
    final Widget card = FushiPressScale(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: RoundedRectangleBorder(
            borderRadius: FushiM3eShape.cardRadius,
          ),
          canRequestFocus: false,
          onTap: () => unawaited(_playEpisode(episode)),
          child: CollectionEpisodeCard(
            thumb: collectionEpisodeThumb(
              context,
              mediaServerCoverImage(
                _browser,
                episode,
                kind: episode.hasThumb
                    ? MediaServerImageKind.thumb
                    : MediaServerImageKind.primary,
              ),
            ),
            number: '${episode.episodeNumber ?? index + 1}',
            title: episode.name,
            summary: episode.overview,
            meta: <String>[if (duration.isNotEmpty) duration],
            completed: episode.played,
            positionMs: episode.positionMs,
            progress: mediaServerProgress(episode),
            isContinue: isContinue,
          ),
        ),
      ),
    );
    final Widget focusable = FushiFocusRoot.maybeControllerOf(context) == null
        ? card
        : Actions(
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  unawaited(_playEpisode(episode));
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
          );
    return KeyedSubtree(
      key: ValueKey<String>('media-server-episode-${episode.id}'),
      child: focusable,
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
