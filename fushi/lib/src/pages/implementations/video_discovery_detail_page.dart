import 'dart:async';

import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_widgets.dart';
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
    // 状态行都从这一份状态取值。
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
              final VideoDiscoveryItem item = details.item;
              final ImageProvider? backdrop = _networkImage(item.backdropUrl) ??
                  _networkImage(item.posterUrl);
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
              // M3E 详情骨架（MediaDetailLayout）的滚动视图只放 SliverToBoxAdapter /
              // SingleChildScrollView（非懒加载，子节点不随滚动回收），本身不触发；
              // 真正的懒加载只有人物条与相关作品条两条横向列表 —— 它们各自用
              // SelectionContainer.disabled 把整条排除在选区外，Selectable 一个都
              // 不注册，触发条件从源头消失。
              //
              // 新增横向/懒加载区块请照做，守卫见
              // test/pages/video_discovery_detail_selectable_test.dart。
              return Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: SelectionArea(
                      child: FushiEntranceScope(
                        child: MediaDetailLayout(
                          key: const PageStorageKey<String>(
                            'video-discovery-detail-scroll',
                          ),
                          backdrop: backdrop,
                          backdropBlur: item.backdropUrl == null ? 28 : 16,
                          header: _buildHero(item, state, backdrop),
                          slivers: <Widget>[
                            if (snapshot.hasError)
                              SliverToBoxAdapter(child: _buildDetailsError())
                            else ...<Widget>[
                              if (snapshot.connectionState !=
                                  ConnectionState.done)
                                SliverToBoxAdapter(
                                  child: _buildDetailsLoading(details),
                                ),
                              SliverToBoxAdapter(
                                child: FushiStaggeredEntrance(
                                  index: 0,
                                  child: _buildOverview(details),
                                ),
                              ),
                              if (details.people.isNotEmpty)
                                SliverToBoxAdapter(
                                  child: FushiStaggeredEntrance(
                                    index: 1,
                                    child: _buildPeople(details.people),
                                  ),
                                ),
                              if (details.related.isNotEmpty)
                                SliverToBoxAdapter(
                                  child: FushiStaggeredEntrance(
                                    index: 2,
                                    child: _buildRelated(details.related),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 返回键：悬浮圆胶囊（M3E 页头浮动工具栏同一形态 / Apple 玻璃
                  // 圆钮），压在 hero 背景上、滚动时常驻。
                  PositionedDirectional(
                    top: 0,
                    start: 0,
                    child: SafeArea(
                      child: Padding(
                        padding: EdgeInsets.all(tokens.spacing.gap),
                        child: const FushiRouteBackButton(),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// 详情 hero（M3E 详情骨架）：剧照（没有就用海报）模糊大背景 + 色晕、海报
  /// 封面卡、Display 级标题 + 原名、年份 / 类型 / 评分 chip、主操作按钮组，页脚
  /// 是可复制的罗马音 / 英文名、题材标签与获取状态。
  Widget _buildHero(
    VideoDiscoveryItem item,
    VideoDiscoveryAcquisitionState state,
    ImageProvider? backdrop,
  ) {
    final ImageProvider? poster = _networkImage(item.posterUrl);
    final double? score = item.score;
    return MediaDetailHero(
      title: item.reference.title,
      originalTitle: item.reference.originalTitle,
      backdrop: backdrop,
      backdropBlur: item.backdropUrl == null ? 28 : 16,
      cover: poster == null
          ? const MediaDetailCoverPlaceholder(icon: FushiIcons.video)
          : Image(
              image: poster,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) =>
                  const MediaDetailCoverPlaceholder(icon: FushiIcons.video),
            ),
      chips: <MediaDetailChip>[
        if (item.reference.year != null)
          MediaDetailChip(
            '${item.reference.year}',
            icon: FushiIcons.calendar,
          ),
        MediaDetailChip(
          _kindLabel(item.reference.discoveryCategory),
          icon: FushiIcons.video,
        ),
        if (score != null)
          MediaDetailChip(
            score.toStringAsFixed(1),
            icon: FushiIcons.filled(FushiIcons.star),
            tone: MediaDetailChipTone.primary,
          ),
      ],
      actions: _buildActionBar(item, state),
      footer: _buildHeroFooter(item, state),
    );
  }

  /// 已在库能播 → 「播放」是主动作；否则「找资源」（获取）是主动作。
  bool _playIsPrimary(VideoDiscoveryAcquisitionState state) =>
      state.isInLibrary && widget.actions.onPlay != null;

  /// 主操作按钮组：主按钮（播放 / 找资源，filled 大号；下载在飞时挂不确定波浪
  /// 进度）+ 次按钮（tonal：找资源〔播放占主位时〕/ 订阅 / 字幕）+「⋯」（AI 获取、
  /// 下载任务）。
  Widget _buildActionBar(
    VideoDiscoveryItem item,
    VideoDiscoveryAcquisitionState state,
  ) {
    final bool playPrimary = _playIsPrimary(state);
    // 「下载中」不门控「找资源」。队列层**从来没有** per-series 并发限制
    // （enqueue 不查重、claimNextVideoDownloadJob 无 per-series 谓词、唯一的
    // 去重门是「同后端指纹 + 同 info hash」即同一个种子），限制只存在于这颗
    // 按钮的 disabled 上。用户「感觉下的源不对劲，想再下一个，但是下不了，只能
    // 取消或者等下载结束」——那是个纯 UI 造出来的死局。
    final VoidCallback? onSearchResource =
        widget.actions.onSearchResource == null
            ? null
            : () => unawaited(widget.actions.onSearchResource!(context, item));
    const Key resourceKey = ValueKey<String>('video-discovery-search-resource');
    final Widget primary = playPrimary
        ? MediaDetailPrimaryButton(
            buttonKey: const ValueKey<String>('video-discovery-play'),
            icon: FushiIcons.play,
            label: t.video_discovery_play,
            progress: state.isBusy ? -1 : null,
            onPressed: state.isBusy
                ? null
                : () => unawaited(widget.actions.onPlay!(context, item)),
          )
        : MediaDetailPrimaryButton(
            buttonKey: resourceKey,
            icon: FushiIcons.search,
            label: t.video_discovery_resource_search,
            progress: state.isBusy ? -1 : null,
            onPressed: onSearchResource,
          );
    final List<MediaDetailMenuItem> more = <MediaDetailMenuItem>[
      if (widget.actions.onAiAcquire case final ValueChanged<String?> onAi)
        MediaDetailMenuItem(
          key: const ValueKey<String>('video-discovery-detail-ai-acquire'),
          icon: FushiIcons.aiAssistant,
          label: t.ai_video_acquire_entry,
          onSelected: () => onAi(item.reference.title),
        ),
      if (widget.actions.onOpenDownloads case final VoidCallback onDownloads)
        MediaDetailMenuItem(
          key: const ValueKey<String>('video-discovery-detail-downloads-menu'),
          icon: FushiIcons.download,
          label: t.download_tasks_tab,
          onSelected: onDownloads,
        ),
    ];
    return MediaDetailActionBar(
      key: const ValueKey<String>('video-discovery-actions'),
      primary: primary,
      secondary: <Widget>[
        if (playPrimary)
          MediaDetailSecondaryButton(
            buttonKey: resourceKey,
            icon: FushiIcons.search,
            label: t.video_discovery_resource_search,
            onPressed: onSearchResource,
          ),
        _buildSubscribeButton(item, state),
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('video-discovery-search-subtitle'),
          icon: FushiIcons.subtitles,
          label: t.video_discovery_subtitle_search,
          // 下载进行中仍允许选择字幕并附加到持久任务；busy 只门控会创建新
          // 下载/订阅副作用的动作。
          onPressed: widget.actions.onSearchSubtitle == null
              ? null
              : () => unawaited(
                    widget.actions.onSearchSubtitle!(context, item),
                  ),
        ),
      ],
      more: more.isEmpty
          ? null
          : MediaDetailMoreButton(
              buttonKey: const ValueKey<String>('video-discovery-detail-more'),
              items: more,
            ),
    );
  }

  /// 订阅（已订阅 = selected，点开订阅管理）。
  Widget _buildSubscribeButton(
    VideoDiscoveryItem item,
    VideoDiscoveryAcquisitionState state,
  ) {
    final VoidCallback? onPressed = state.isBusy
        ? null
        : state.isSubscribed && widget.actions.onOpenSubscriptions != null
            ? widget.actions.onOpenSubscriptions
            : widget.actions.onSubscribe == null
                ? null
                : () => unawaited(
                      widget.actions.onSubscribe!(context, item),
                    );
    return MediaDetailSecondaryButton(
      buttonKey: const ValueKey<String>('video-discovery-subscribe'),
      icon: FushiIcons.favorite,
      selected: state.isSubscribed,
      label: state.isSubscribed
          ? t.video_discovery_subscription_manage
          : t.video_discovery_subscribe,
      onPressed: onPressed,
    );
  }

  /// hero 页脚：罗马音 / 英文名（可复制）、题材标签、获取状态与在飞下载的
  /// 取消 / 查看任务。
  Widget _buildHeroFooter(
    VideoDiscoveryItem item,
    VideoDiscoveryAcquisitionState state,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<String> latinTitles = videoDiscoveryLatinTitles(item);
    final List<String> genres = item.genres.take(6).toList();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final String latinTitle in latinTitles)
            _buildCopyableTitle(latinTitle, tokens),
          if (genres.isNotEmpty) ...<Widget>[
            if (latinTitles.isNotEmpty) SizedBox(height: tokens.spacing.gap),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String genre in genres) FushiTagChip(label: genre),
              ],
            ),
          ],
          if (latinTitles.isNotEmpty || genres.isNotEmpty)
            SizedBox(height: tokens.spacing.card),
          _buildAcquisitionStatus(state),
          if (state.isBusy && state.activeJobIds.isNotEmpty)
            _buildBusyActions(state),
        ],
      ),
    );
  }

  Widget _buildAcquisitionStatus(VideoDiscoveryAcquisitionState state) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (state.isBusy)
          const SizedBox.square(
            dimension: 16,
            child: FushiCircularProgressIndicator(strokeWidth: 2),
          )
        else
          FushiIcon(
            state.isInLibrary
                ? FushiIcons.filled(FushiIcons.success)
                : FushiIcons.cloudDownload,
            size: 18,
            color: state.isInLibrary ? cs.primary : cs.onSurfaceVariant,
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
            style: context.fushiType.labelLarge.copyWith(
              color: cs.onSurfaceVariant,
            ),
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
              icon: const FushiIcon(FushiIcons.close, size: 16),
              label: Text(t.cancel),
            ),
          if (widget.actions.onOpenDownloads != null)
            FushiTextButton.icon(
              key: const ValueKey<String>('video-discovery-detail-downloads'),
              onPressed: widget.actions.onOpenDownloads,
              icon: const FushiIcon(FushiIcons.download, size: 16),
              label: Text(t.download_tasks_tab),
            ),
        ],
      ),
    );
  }

  /// 详情加载中：已有简介 / 资料时只顶一条细进度（不闪回空态）；什么都没有时
  /// 给段落骨架。
  Widget _buildDetailsLoading(VideoDiscoveryDetailData details) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String overview = details.item.overview?.trim() ?? '';
    if (overview.isNotEmpty || details.facts.isNotEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.page,
          vertical: tokens.spacing.gap,
        ),
        child: const FushiLinearProgressIndicator(minHeight: 2),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.section,
        tokens.spacing.page,
        0,
      ),
      child: FushiSkeletonShimmer(
        child: Column(
          key: const ValueKey<String>('video-discovery-detail-loading'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FushiSkeleton.line(widthFactor: 0.3, height: 22),
            const SizedBox(height: 16),
            FushiSkeleton.line(height: 14),
            const SizedBox(height: 8),
            FushiSkeleton.line(widthFactor: 0.92, height: 14),
            const SizedBox(height: 8),
            FushiSkeleton.line(widthFactor: 0.7, height: 14),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsError() {
    return FushiPlaceholderMessage(
      icon: FushiIcons.cloudOff,
      tone: FushiPlaceholderTone.error,
      message: t.video_discovery_details_load_failed,
      action: FushiFilledButton.tonalIcon(
        key: const ValueKey<String>('video-discovery-detail-retry'),
        onPressed: _retryDetails,
        icon: const FushiIcon(FushiIcons.refresh),
        label: Text(t.retry),
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
          MediaDetailSectionHeader(t.download_detail_tab_overview),
          if (overview != null && overview.isNotEmpty)
            // BUG-1901：页级 SelectionArea 已让所有文本可选。这里保持普通 Text
            // （selectable: false）—— 嵌套的 SelectableText 会自成一个独立选区，
            // 反而切断与标题/元数据的跨元素拖选。
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: MediaDetailSynopsis(
                key: const ValueKey<String>('video-discovery-overview'),
                text: overview,
                collapsedLines: 6,
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
    return SelectionContainer.disabled(
      child: MediaDetailCastStrip(
        title: t.video_work_cast_crew,
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
        people: <MediaDetailPerson>[
          for (final VideoDiscoveryPerson person in people)
            MediaDetailPerson(
              name: person.name,
              role: person.role,
              image: _networkImage(person.imageUrl),
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

  /// 罗马音 / 英文名一行：文字可选中（页级 SelectionArea），右侧按钮一键复制
  /// （资源站多按罗马音或英文名发布，搜不到时拿去别处搜）。
  Widget _buildCopyableTitle(String value, FushiDesignTokens tokens) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.bodyMedium.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(width: tokens.spacing.gap / 2),
          FushiIconButton(
            icon: FushiIcons.copy,
            size: 16,
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
            icon: FushiIcons.filled(FushiIcons.star),
            iconSize: 12,
            label: score.toStringAsFixed(1),
          ),
      ],
      cover: DiscoveryImageCover(
        image: _networkImage(item.posterUrl),
        placeholderIcon: FushiIcons.video,
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
