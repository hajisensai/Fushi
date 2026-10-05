import 'dart:async';
import 'dart:math' as math;

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart'
    show CollectionHeroBadgeChips, CollectionHeroTagChips;
import 'package:fushi/src/pages/implementations/discovery/discovery_widgets.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/utils.dart';

/// 详情页标题下方可复制的拉丁字母标题：罗马音在前、英文名在后，与展示标题 /
/// 原名重复的（忽略大小写）不再列出。
List<String> videoDiscoveryLatinTitles(VideoDiscoveryItem item) {
  final VideoMetadataWork? work = item.metadataWork;
  final Set<String> seen = <String>{
    item.reference.title.trim().toLowerCase(),
    if (item.reference.originalTitle case final String original)
      original.trim().toLowerCase(),
  };
  return <String>[
    for (final String? value in <String?>[
      work?.romajiTitle,
      work?.englishTitle,
    ])
      if (value != null &&
          value.trim().isNotEmpty &&
          seen.add(value.trim().toLowerCase()))
        value.trim(),
  ];
}

typedef VideoDiscoveryAction = Future<void> Function(
  BuildContext context,
  VideoDiscoveryItem item,
);

typedef VideoDiscoveryDetailLoader = Future<VideoDiscoveryDetailData> Function(
  VideoDiscoveryItem item,
);

typedef VideoDiscoveryStatusWatch = Stream<VideoDiscoveryAcquisitionState>
    Function(VideoMediaReference reference);

/// UI-facing action ports for an online work.
///
/// The discovery surface deliberately does not know about torrent backends,
/// subtitle providers or database rows. The composition root wires those
/// services here, while widget tests can inject deterministic callbacks.
class VideoDiscoveryActions {
  const VideoDiscoveryActions({
    this.loadDetails,
    this.watchStatus,
    this.onSearchResource,
    this.onSearchSubtitle,
    this.onSubscribe,
    this.onPlay,
    this.onOpenDownloads,
    this.onOpenSubscriptions,
    this.onCancelDownloads,
    this.onAiAcquire,
    this.detailsUpdates,
  });

  final VideoDiscoveryDetailLoader? loadDetails;

  /// 详情数据源有了更好的数据时发事件（例如后台刚下好动画 → TMDB 交叉索引，
  /// 资料语言的简介这时才拿得到）：详情页与发现页 Hero 收到后各重取一次
  /// [loadDetails]。null = 数据源不会变。
  final Stream<void>? detailsUpdates;
  final VideoDiscoveryStatusWatch? watchStatus;
  final VideoDiscoveryAction? onSearchResource;
  final VideoDiscoveryAction? onSearchSubtitle;
  final VideoDiscoveryAction? onSubscribe;
  final VideoDiscoveryAction? onPlay;
  final VoidCallback? onOpenDownloads;
  final VoidCallback? onOpenSubscriptions;

  /// 取消本作品当前在飞的下载任务（[VideoDiscoveryAcquisitionState.activeJobIds]）。
  ///
  /// 作品页此前**根本没有取消入口**：唯一的取消按钮在下载任务面板里，而详情页连
  /// 「查看下载」都只在发现**列表**页渲染。用户「感觉下的源不对劲，想再下一个，
  /// 但是下不了，只能取消或者等下载结束」——连取消都得先自己找到下载页。
  final Future<void> Function(List<String> jobIds)? onCancelDownloads;

  /// 打开「AI 下视频」对话页（发现页搜索行的入口）。null = 不渲染入口：AI 提供商
  /// 未指派、下载中心 / 外部发现在本平台不可用（iOS 合规）、或后端 runtime 没起。
  ///
  /// 参数是搜索框里已经输入的文字（空 = 没输入）：对话页拿它直接开聊，用户不用
  /// 把刚打过的作品名再打一遍。
  final ValueChanged<String?>? onAiAcquire;
}

class VideoDiscoveryAcquisitionState {
  const VideoDiscoveryAcquisitionState({
    this.statusLabel,
    this.isSubscribed = false,
    this.isInLibrary = false,
    this.isBusy = false,
    this.activeJobIds = const <String>[],
  });

  final String? statusLabel;
  final bool isSubscribed;
  final bool isInLibrary;
  final bool isBusy;

  /// 本作品当前处于 active 生命周期的下载任务 id。
  ///
  /// 聚合成一个 bool 是不够的：取消需要知道取消**哪几条**，而同一部作品现在可以
  /// 并存多条下载（换源重下时旧的还在跑）。
  final List<String> activeJobIds;
}

class VideoDiscoveryFact {
  const VideoDiscoveryFact({required this.label, required this.value});

  final String label;
  final String value;
}

class VideoDiscoveryPerson {
  const VideoDiscoveryPerson({
    required this.name,
    this.role,
    this.imageUrl,
  });

  final String name;
  final String? role;
  final String? imageUrl;
}

class VideoDiscoveryDetailData {
  VideoDiscoveryDetailData({
    required this.item,
    Iterable<VideoDiscoveryFact> facts = const <VideoDiscoveryFact>[],
    Iterable<VideoDiscoveryPerson> people = const <VideoDiscoveryPerson>[],
    Iterable<VideoDiscoveryItem> related = const <VideoDiscoveryItem>[],
  })  : facts = List<VideoDiscoveryFact>.unmodifiable(facts),
        people = List<VideoDiscoveryPerson>.unmodifiable(people),
        related = List<VideoDiscoveryItem>.unmodifiable(related);

  final VideoDiscoveryItem item;
  final List<VideoDiscoveryFact> facts;
  final List<VideoDiscoveryPerson> people;
  final List<VideoDiscoveryItem> related;
}

/// Lightweight online detail route. It consumes provider-neutral data and
/// never creates a local database work just to render an online result.
class VideoDiscoveryDetailPage extends StatefulWidget {
  const VideoDiscoveryDetailPage({
    required this.item,
    this.actions = const VideoDiscoveryActions(),
    super.key,
  });

  final VideoDiscoveryItem item;
  final VideoDiscoveryActions actions;

  @override
  State<VideoDiscoveryDetailPage> createState() =>
      _VideoDiscoveryDetailPageState();
}

class _VideoDiscoveryDetailPageState extends State<VideoDiscoveryDetailPage> {
  late Future<VideoDiscoveryDetailData> _detailsFuture;
  Stream<VideoDiscoveryAcquisitionState>? _statusStream;
  StreamSubscription<void>? _detailsUpdates;

  @override
  void initState() {
    super.initState();
    _detailsFuture = _loadDetails();
    _statusStream = _watchStatus();
    _listenDetailsUpdates();
  }

  /// 数据源变好（如交叉索引后台就绪）时原地重取：FutureBuilder 换 future 时
  /// 保留上一份数据，页面不会闪回空态。
  void _listenDetailsUpdates() {
    unawaited(_detailsUpdates?.cancel());
    _detailsUpdates = widget.actions.detailsUpdates?.listen((_) {
      if (!mounted) return;
      setState(() => _detailsFuture = _loadDetails());
    });
  }

  @override
  void dispose() {
    unawaited(_detailsUpdates?.cancel());
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VideoDiscoveryDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool itemChanged = oldWidget.item.reference.canonicalIdentityKey !=
        widget.item.reference.canonicalIdentityKey;
    if (itemChanged ||
        !identical(
          oldWidget.actions.loadDetails,
          widget.actions.loadDetails,
        )) {
      _detailsFuture = _loadDetails();
    }
    if (itemChanged ||
        !identical(
          oldWidget.actions.watchStatus,
          widget.actions.watchStatus,
        )) {
      _statusStream = _watchStatus();
    }
    if (!identical(
      oldWidget.actions.detailsUpdates,
      widget.actions.detailsUpdates,
    )) {
      _listenDetailsUpdates();
    }
  }

  Future<VideoDiscoveryDetailData> _loadDetails() async {
    final VideoDiscoveryDetailLoader? loader = widget.actions.loadDetails;
    if (loader == null) return VideoDiscoveryDetailData(item: widget.item);
    return loader(widget.item);
  }

  Stream<VideoDiscoveryAcquisitionState>? _watchStatus() =>
      widget.actions.watchStatus?.call(widget.item.reference);

  void _retryDetails() {
    setState(() {
      _detailsFuture = _loadDetails();
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 状态流只订阅一次（单订阅流 + 「watchStatus 只调一次」契约），hero 主按钮与
    // 下方操作区都从这一份状态取值。
    return Scaffold(
      backgroundColor: tokens.surfaces.page,
      body: StreamBuilder<VideoDiscoveryAcquisitionState>(
        stream: _statusStream,
        initialData: const VideoDiscoveryAcquisitionState(),
        builder: (
          BuildContext context,
          AsyncSnapshot<VideoDiscoveryAcquisitionState> statusSnapshot,
        ) {
          final VideoDiscoveryAcquisitionState state =
              statusSnapshot.data ?? const VideoDiscoveryAcquisitionState();
          return FutureBuilder<VideoDiscoveryDetailData>(
            future: _detailsFuture,
            initialData: VideoDiscoveryDetailData(item: widget.item),
            builder: (
              BuildContext context,
              AsyncSnapshot<VideoDiscoveryDetailData> snapshot,
            ) {
              final VideoDiscoveryDetailData details =
                  snapshot.data ?? VideoDiscoveryDetailData(item: widget.item);
              // BUG-1901：整页一个 SelectionArea，而不是逐个把 Text 换成
              // SelectableText。
              //
              // 用户报「这个界面，不能复制文件名，下面的简介可以」——根因不是包裹
              // 范围问题，而是**逐 widget 手工选型**：谁被想起来写成 SelectableText
              // 谁能选。页级 SelectionArea 让「可选」成为默认，特殊情况消失，还顺带
              // 支持跨元素拖选（标题连着简介一起选）。按钮的点击不受影响。
              //
              // ⚠ 不变式：**懒加载列表不得裸露在这个 SelectionArea 里**。
              //
              // 上游 flutter#119355（本仓已吃过两次：BUG-694、BUG-1582）——
              // SelectionArea 套 Scrollable 时，「选中文字 → 滚走（端点所在 item 被
              // itemBuilder 回收）→ 再长按」会让 _ScrollableSelectionContainerDelegate
              // 仍持有指向已回收 Selectable 的 currentSelectionEndIndex，
              // _updateDragLocationsFromGeometries() 无条件读 endSelectionPoint! 抛
              // 空断言。debug 下 assert(geometry.hasSelection) 先一步拦住，**只在
              // release 崩**。
              //
              // 本页外层 CustomScrollView 用的全是 SliverToBoxAdapter（非懒加载，
              // 子节点不随滚动回收），本身不触发；真正的懒加载只有 _buildPeople /
              // _buildRelated 两条横向列表 —— 它们各自用
              // SelectionContainer.disabled 把整条排除在选区外，Selectable 一个都
              // 不注册，触发条件从源头消失。
              //
              // 新增横向/懒加载区块请照做，守卫见
              // test/pages/video_discovery_detail_selectable_test.dart。
              return SelectionArea(
                  child: CustomScrollView(
                key: const PageStorageKey<String>(
                    'video-discovery-detail-scroll'),
                slivers: <Widget>[
                  _buildHero(details.item, state),
                  SliverToBoxAdapter(
                    child: _buildActionSection(details.item, state),
                  ),
                  if (snapshot.hasError)
                    SliverToBoxAdapter(child: _buildDetailsError())
                  else ...<Widget>[
                    if (snapshot.connectionState != ConnectionState.done)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: tokens.spacing.page,
                            vertical: tokens.spacing.gap,
                          ),
                          child: const FushiLinearProgressIndicator(
                            minHeight: 2,
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(child: _buildOverview(details)),
                    if (details.people.isNotEmpty)
                      SliverToBoxAdapter(child: _buildPeople(details.people)),
                    if (details.related.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _buildRelated(details.related),
                      ),
                  ],
                  SliverToBoxAdapter(
                    child: SizedBox(height: tokens.spacing.section),
                  ),
                ],
              ));
            },
          );
        },
      ),
    );
  }

  /// 详情 hero：合集详情 hero 的样式语言——剧照 / 海报铺底 + 上浅下深渐变、
  /// 白字大标题、元信息胶囊、题材胶囊、白底 overImage 主按钮。
  Widget _buildHero(
    VideoDiscoveryItem item,
    VideoDiscoveryAcquisitionState state,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ImageProvider? backdrop = _networkImage(item.backdropUrl);
    final ImageProvider? poster = _networkImage(item.posterUrl);
    final Size viewport = MediaQuery.sizeOf(context);
    final double width = viewport.width;
    final bool compact = width < kVideoDiscoveryCompactWidth;
    // 与合集详情 hero 同口径：约 60% 视口高，不再按 16:9 撑到整屏。
    final double expandedHeight = math.min(
      videoDiscoveryHeroHeightForViewport(width, viewport.height),
      math.max(compact ? 460.0 : 430.0, viewport.height * 0.62),
    );
    final String? original = item.reference.originalTitle?.trim();
    return FushiSliverAppBar(
      pinned: true,
      expandedHeight: expandedHeight,
      backgroundColor: tokens.surfaces.page,
      surfaceTintColor: Colors.transparent,
      // 返回键压在 hero 图上：深色圆底 + 白色箭头，浅色主题收起后也看得见。
      leading: Padding(
        padding: const EdgeInsets.all(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: coverBadgeScrim(context),
            shape: BoxShape.circle,
          ),
          child: const BackButton(color: Colors.white),
        ),
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            DiscoveryHeroBackdrop(
              backdrop: backdrop,
              poster: poster,
              showPoster: !compact,
              foregroundPadding: EdgeInsetsDirectional.fromSTEB(
                0,
                88,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
            ),
            SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  compact ? 64 : 76,
                  tokens.spacing.page,
                  tokens.spacing.section,
                ),
                child: Align(
                  alignment: AlignmentDirectional.bottomStart,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: compact ? 620 : 680),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.reference.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: DiscoveryHeroText.title(
                            context,
                            wide: !compact,
                          ),
                        ),
                        if (original != null &&
                            original.isNotEmpty &&
                            original != item.reference.title) ...<Widget>[
                          SizedBox(height: tokens.spacing.gap / 2),
                          Text(
                            original,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DiscoveryHeroText.meta(context),
                          ),
                        ],
                        for (final String latinTitle
                            in videoDiscoveryLatinTitles(item))
                          _buildCopyableTitle(latinTitle, tokens),
                        SizedBox(height: tokens.spacing.gap),
                        CollectionHeroBadgeChips(parts: _badgeParts(item)),
                        if (item.genres.isNotEmpty) ...<Widget>[
                          SizedBox(height: tokens.spacing.gap),
                          CollectionHeroTagChips(
                            names: item.genres.take(6).toList(),
                          ),
                        ],
                        SizedBox(height: tokens.spacing.card),
                        _buildPrimaryAction(item, state),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// hero 元信息胶囊：年份 / 类型 / ★ 评分，逐项存在才出。
  List<String> _badgeParts(VideoDiscoveryItem item) => <String>[
        if (item.reference.year != null) '${item.reference.year}',
        _kindLabel(item.reference.discoveryCategory),
        if (item.score != null) '★ ${item.score!.toStringAsFixed(1)}',
      ];

  /// 已在库能播 → 「播放」；否则「订阅」是主动作。压在 hero 上：Apple 白底
  /// prominent 玻璃（Apple TV「播放」），MD3 主色实心按钮。
  bool _playIsPrimary(VideoDiscoveryAcquisitionState state) =>
      state.isInLibrary && widget.actions.onPlay != null;

  Widget _buildPrimaryAction(
    VideoDiscoveryItem item,
    VideoDiscoveryAcquisitionState state,
  ) {
    if (_playIsPrimary(state)) {
      return FushiFilledButton.icon(
        key: const ValueKey<String>('video-discovery-play'),
        overImage: true,
        onPressed: state.isBusy
            ? null
            : () => unawaited(widget.actions.onPlay!(context, item)),
        icon: const FushiIcon(Icons.play_arrow_rounded),
        label: Text(t.video_discovery_play),
      );
    }
    return _buildSubscribeButton(item, state, primary: true);
  }

  Widget _buildSubscribeButton(
    VideoDiscoveryItem item,
    VideoDiscoveryAcquisitionState state, {
    required bool primary,
  }) {
    final VoidCallback? onPressed = state.isBusy
        ? null
        : state.isSubscribed && widget.actions.onOpenSubscriptions != null
            ? widget.actions.onOpenSubscriptions
            : widget.actions.onSubscribe == null
                ? null
                : () => unawaited(
                      widget.actions.onSubscribe!(context, item),
                    );
    final Widget icon = FushiIcon(
      state.isSubscribed
          ? Icons.favorite_rounded
          : Icons.favorite_border_rounded,
    );
    final Widget label = Text(
      state.isSubscribed
          ? t.video_discovery_subscription_manage
          : t.video_discovery_subscribe,
    );
    const Key key = ValueKey<String>('video-discovery-subscribe');
    if (primary) {
      return FushiFilledButton.icon(
        key: key,
        overImage: true,
        onPressed: onPressed,
        icon: icon,
        label: label,
      );
    }
    return FushiFilledButton.tonalIcon(
      key: key,
      onPressed: onPressed,
      icon: icon,
      label: label,
    );
  }

  /// hero 下方的操作区（实色页面底上）：资源 / 字幕搜索 +（播放是主动作时）
  /// 订阅，再下面是获取状态与在飞下载的取消 / 查看任务。
  Widget _buildActionSection(
    VideoDiscoveryItem item,
    VideoDiscoveryAcquisitionState state,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.card,
        tokens.spacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildActions(item, state),
          SizedBox(height: tokens.spacing.gap),
          _buildAcquisitionStatus(state),
          if (state.isBusy && state.activeJobIds.isNotEmpty)
            _buildBusyActions(state),
        ],
      ),
    );
  }

  Widget _buildActions(
    VideoDiscoveryItem item,
    VideoDiscoveryAcquisitionState state,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: <Widget>[
        FushiOutlinedButton.icon(
          key: const ValueKey<String>(
            'video-discovery-search-resource',
          ),
          // 「下载中」不再门控这里。队列层**从来没有** per-series 并发限制
          // （enqueue 不查重、claimNextVideoDownloadJob 无 per-series 谓词、
          // 唯一的去重门是「同后端指纹 + 同 info hash」即同一个种子），限制只存在
          // 于这颗按钮的 disabled 上。用户「感觉下的源不对劲，想再下一个，但是
          // 下不了，只能取消或者等下载结束」——那是个纯 UI 造出来的死局。
          onPressed: widget.actions.onSearchResource == null
              ? null
              : () => unawaited(
                    widget.actions.onSearchResource!(context, item),
                  ),
          icon: const FushiIcon(Icons.search_rounded),
          label: Text(t.video_discovery_resource_search),
        ),
        FushiOutlinedButton.icon(
          key: const ValueKey<String>(
            'video-discovery-search-subtitle',
          ),
          // 下载进行中仍允许选择字幕并附加到持久任务；busy 只门控会创建新
          // 下载/订阅副作用的动作。
          onPressed: widget.actions.onSearchSubtitle == null
              ? null
              : () => unawaited(
                    widget.actions.onSearchSubtitle!(context, item),
                  ),
          icon: const FushiIcon(Icons.subtitles_outlined),
          label: Text(t.video_discovery_subtitle_search),
        ),
        // 订阅是 hero 主按钮时这里不重复；播放占了主位才放到这里。
        if (_playIsPrimary(state))
          _buildSubscribeButton(item, state, primary: false),
      ],
    );
  }

  Widget _buildAcquisitionStatus(VideoDiscoveryAcquisitionState state) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (state.isBusy) ...<Widget>[
          const SizedBox.square(
            dimension: 14,
            child: FushiCircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
        ] else
          FushiIcon(
            state.isInLibrary
                ? Icons.check_circle_outline_rounded
                : Icons.route_outlined,
            size: 18,
          ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            state.statusLabel ??
                (state.isInLibrary
                    ? t.video_discovery_in_library
                    : t.video_discovery_pipeline_idle),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: FushiDesignTokens.of(context).type.metadata,
          ),
        ),
      ],
    );
  }

  /// 在飞下载的操作行：取消 / 查看任务。
  ///
  /// **单独一行**，不塞进上面那个状态 Row：窗口下限是 360dp（
  /// [DesktopWindowPlacement.minimumSize]），状态文案本身就已经在抢宽度，再并排
  /// 两颗带图标的按钮必然溢出。Wrap 让它在更窄时自己换行。
  Widget _buildBusyActions(VideoDiscoveryAcquisitionState state) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
      child: Wrap(
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap / 2,
        children: <Widget>[
          if (widget.actions.onCancelDownloads != null)
            FushiTextButton.icon(
              key: const ValueKey<String>('video-discovery-cancel-download'),
              onPressed: () => unawaited(
                widget.actions.onCancelDownloads!(state.activeJobIds),
              ),
              icon: const FushiIcon(Icons.close, size: 16),
              label: Text(t.cancel),
            ),
          if (widget.actions.onOpenDownloads != null)
            FushiTextButton.icon(
              key: const ValueKey<String>('video-discovery-detail-downloads'),
              onPressed: widget.actions.onOpenDownloads,
              icon: const FushiIcon(Icons.download_outlined, size: 16),
              label: Text(t.download_tasks_tab),
            ),
        ],
      ),
    );
  }

  Widget _buildDetailsError() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.page),
      child: FushiCard(
        child: Row(
          children: <Widget>[
            const FushiIcon(Icons.cloud_off_outlined),
            SizedBox(width: tokens.spacing.gap),
            Expanded(child: Text(t.video_discovery_details_load_failed)),
            FushiTextButton(onPressed: _retryDetails, child: Text(t.retry)),
          ],
        ),
      ),
    );
  }

  Widget _buildOverview(VideoDiscoveryDetailData details) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? overview = details.item.overview?.trim();
    if ((overview == null || overview.isEmpty) && details.facts.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          FushiSectionTitle(
            t.download_detail_tab_overview,
            padding: EdgeInsets.only(
              top: tokens.spacing.section,
              bottom: tokens.spacing.gap,
            ),
          ),
          if (overview != null && overview.isNotEmpty)
            // BUG-1901：页级 SelectionArea 已让所有文本可选。这里保持普通 Text ——
            // 嵌套的 SelectableText 会自成一个独立选区，反而切断与标题/元数据的
            // 跨元素拖选，是 SelectionArea 之前遗留的逐 widget 写法。
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Text(
                overview,
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(height: 1.5),
              ),
            ),
          if (details.facts.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
            // 资料两列：实色分组卡（MD3 surfaceContainerLow / Apple
            // secondarySystemGroupedBackground），标签灰字、值正文。
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: FushiCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final (int index, VideoDiscoveryFact fact)
                        in details.facts.indexed)
                      Padding(
                        padding: EdgeInsets.only(
                          top: index == 0 ? 0 : tokens.spacing.gap,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            SizedBox(
                              width: 116,
                              child: Text(
                                fact.label,
                                style: tokens.type.metadata,
                              ),
                            ),
                            SizedBox(width: tokens.spacing.gap),
                            Expanded(
                              child: Text(
                                fact.value,
                                style: tokens.type.listTitle,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPeople(List<VideoDiscoveryPerson> people) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.section,
        0,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          FushiSectionTitle(
            t.video_work_cast_crew,
            padding: EdgeInsetsDirectional.only(
              end: tokens.spacing.page,
              bottom: tokens.spacing.card,
            ),
          ),
          // flutter#119355（本仓 BUG-694 / BUG-1582 同一条 release-only 崩溃）：
          // 懒加载列表不得进入页级 SelectionArea 的选区。详见 build() 里
          // SelectionArea 处的长注释。这一层把整条横向人物条排除在选区之外——
          // 里面的 Selectable 一个都不注册，回收也就无从「回收掉选区端点」。
          //
          // 顺带解掉桌面端的手势争抢：HorizontalDragScrollable 把
          // PointerDeviceKind.mouse 塞进了 dragDevices，而 SelectableRegion 对鼠标
          // 用 PanGestureRecognizer，两者在同一竞技场里抢「鼠标按下横拖」到底算
          // 「拖着滚」还是「刷选区」（精确指针下 horizontal 的 hitSlop=1 <
          // pan 的 panSlop=2，横拖多半是滚动赢，但斜拖/纵拖会被选区抢走并触发外层
          // 纵向视口的边缘自动滚动）。排除选区后这条竞争彻底消失，鼠标横拖恒为滚动。
          SelectionContainer.disabled(
            child: SizedBox(
              height: 142,
              child: HorizontalDragScrollable(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: people.length,
                  separatorBuilder: (_, __) =>
                      SizedBox(width: tokens.spacing.card),
                  itemBuilder: (BuildContext context, int index) {
                    final VideoDiscoveryPerson person = people[index];
                    final ImageProvider? image = _networkImage(person.imageUrl);
                    return SizedBox(
                      width: 92,
                      child: Column(
                        children: <Widget>[
                          CircleAvatar(
                            radius: 38,
                            backgroundColor: tokens.surfaces.group,
                            backgroundImage: image,
                            child: image == null
                                ? const FushiIcon(Icons.person_outline_rounded)
                                : null,
                          ),
                          SizedBox(height: tokens.spacing.gap),
                          Text(
                            person.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.type.listTitle,
                          ),
                          if (person.role?.trim().isNotEmpty == true)
                            Text(
                              person.role!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.type.metadata,
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRelated(List<VideoDiscoveryItem> related) {
    // flutter#119355：同上，相关作品条也排除在页级选区之外。这里额外多一层
    // 理由——卡片本身是点击目标（pushReplacement 进下一部作品），把它变成可
    // 拖选的文本区只会让「按下拖一下」在导航与刷选区之间摇摆。
    return SelectionContainer.disabled(
      child: DiscoveryShelf(
        title: t.collection_related_title,
        storageKey: 'video-discovery-related',
        itemWidth: 140,
        itemCount: related.length,
        itemBuilder: (BuildContext context, int index) => _RelatedWorkCard(
          item: related[index],
          onTap: () {
            Navigator.pushReplacement<void, void>(
              context,
              adaptivePageRoute<void>(
                context: context,
                builder: (_) => VideoDiscoveryDetailPage(
                  item: related[index],
                  actions: widget.actions,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 罗马音 / 英文名一行：文字可选中，右侧按钮一键复制（资源站多按罗马音或
  /// 英文名发布，搜不到时拿去别处搜）。
  Widget _buildCopyableTitle(String value, FushiDesignTokens tokens) {
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: SelectableText(
              value,
              maxLines: 1,
              style: DiscoveryHeroText.meta(context),
            ),
          ),
          SizedBox(width: tokens.spacing.gap / 2),
          FushiIconButton(
            icon: Icons.copy,
            size: 16,
            // 压在 hero 深色渐变上：白色图标。
            enabledColor: Colors.white70,
            tooltip: t.copy,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: value));
              FushiToast.show(
                msg: t.copied_to_clipboard,
                severity: ToastSeverity.success,
              );
            },
          ),
        ],
      ),
    );
  }

  String _kindLabel(VideoDiscoveryCategory category) => switch (category) {
        VideoDiscoveryCategory.movie => t.collection_relation_movie,
        VideoDiscoveryCategory.tv => t.series,
        VideoDiscoveryCategory.anime => t.media_tracking_anime,
      };
}

class _RelatedWorkCard extends StatelessWidget {
  const _RelatedWorkCard({required this.item, required this.onTap});

  final VideoDiscoveryItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String stableId = item.reference.canonicalIdentityKey;
    final double? score = item.score;
    return DiscoveryCoverCard(
      key: ValueKey<String>('video-discovery-related-$stableId'),
      focusId: FushiFocusId('video-discovery-related-$stableId'),
      title: item.reference.title,
      subtitle: _relatedMetadata(item),
      titleMaxLines: 1,
      onTap: onTap,
      badges: <Widget>[
        if (score != null)
          CoverBadge(
            icon: Icons.star_rounded,
            iconSize: 12,
            label: score.toStringAsFixed(1),
          ),
      ],
      cover: DiscoveryImageCover(
        image: _networkImage(item.posterUrl),
        placeholderIcon: Icons.movie_outlined,
      ),
    );
  }

  String _relatedMetadata(VideoDiscoveryItem item) => <String>[
        if (item.reference.year != null) '${item.reference.year}',
        item.reference.discoveryCategory.name,
      ].join(' · ');
}

ImageProvider? _networkImage(String? url) {
  final String value = url?.trim() ?? '';
  return value.isEmpty ? null : AppCachedHttpImage(value);
}
