import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/cover_ui/landscape_cover_image.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/utils.dart';

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
  });

  final VideoDiscoveryDetailLoader? loadDetails;
  final VideoDiscoveryStatusWatch? watchStatus;
  final VideoDiscoveryAction? onSearchResource;
  final VideoDiscoveryAction? onSearchSubtitle;
  final VideoDiscoveryAction? onSubscribe;
  final VideoDiscoveryAction? onPlay;
  final VoidCallback? onOpenDownloads;
  final VoidCallback? onOpenSubscriptions;
}

class VideoDiscoveryAcquisitionState {
  const VideoDiscoveryAcquisitionState({
    this.statusLabel,
    this.isSubscribed = false,
    this.isInLibrary = false,
    this.isBusy = false,
  });

  final String? statusLabel;
  final bool isSubscribed;
  final bool isInLibrary;
  final bool isBusy;
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

  @override
  void initState() {
    super.initState();
    _detailsFuture = _loadDetails();
    _statusStream = _watchStatus();
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
    return Scaffold(
      backgroundColor: tokens.surfaces.page,
      body: FutureBuilder<VideoDiscoveryDetailData>(
        future: _detailsFuture,
        initialData: VideoDiscoveryDetailData(item: widget.item),
        builder: (
          BuildContext context,
          AsyncSnapshot<VideoDiscoveryDetailData> snapshot,
        ) {
          final VideoDiscoveryDetailData details =
              snapshot.data ?? VideoDiscoveryDetailData(item: widget.item);
          // BUG-1901：整页一个 SelectionArea，而不是逐个把 Text 换成 SelectableText。
          //
          // 用户报「这个界面，不能复制文件名，下面的简介可以」——根因不是包裹范围问题
          // （改前全 fushi/lib 只有日志查看器一处 SelectionArea，与本页毫无关系），
          // 而是**逐 widget 手工选型**：谁被想起来写成 SelectableText 谁能选。改前全页
          // 15 个文本元素只有简介和 facts 右列 2 个可选，标题、原标题、年份/类型、评分、
          // 演职人员、相关作品全不可选。
          //
          // 逐个补 SelectableText 只是把这个特殊情况再复制 13 份，下次加字段照样漏。
          // 页级 SelectionArea 让「可选」成为默认，特殊情况消失，还顺带支持跨元素拖选
          // （标题连着简介一起选）。按钮的点击不受影响。
          //
          // ⚠ 不变式：**懒加载列表不得裸露在这个 SelectionArea 里**。
          //
          // 上游 flutter#119355（本仓已吃过两次：BUG-694、BUG-1582）——SelectionArea
          // 套 Scrollable 时，「选中文字 → 滚走（端点所在 item 被 itemBuilder 回收）
          // → 再长按」会让 _ScrollableSelectionContainerDelegate 仍持有指向已回收
          // Selectable 的 currentSelectionEndIndex，
          // _updateDragLocationsFromGeometries() 无条件读 endSelectionPoint! 抛空断言。
          // debug 下 assert(geometry.hasSelection) 先一步拦住，**只在 release 崩**。
          //
          // 本页外层 CustomScrollView 用的全是 SliverToBoxAdapter（非懒加载，子节点
          // 不随滚动回收），本身不触发；真正的懒加载只有 _buildPeople /
          // _buildRelated 两条横向 ListView.separated —— 它们各自用
          // SelectionContainer.disabled 把整条排除在选区外，Selectable 一个都不注册，
          // 触发条件从源头消失（而不是像日志面板那样事后清选区缓解：那里的懒加载列表
          // 正是用户要选的正文，只能缓解；这里横向卡片条本就不需要被选中）。
          //
          // 新增横向/懒加载区块请照做，守卫见
          // test/pages/video_discovery_detail_selectable_test.dart。
          return SelectionArea(
              child: CustomScrollView(
            key: const PageStorageKey<String>('video-discovery-detail-scroll'),
            slivers: <Widget>[
              _buildHero(details.item),
              if (snapshot.hasError)
                SliverToBoxAdapter(child: _buildDetailsError())
              else ...<Widget>[
                if (snapshot.connectionState != ConnectionState.done)
                  const SliverToBoxAdapter(
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                SliverToBoxAdapter(child: _buildOverview(details)),
                if (details.people.isNotEmpty)
                  SliverToBoxAdapter(child: _buildPeople(details.people)),
                if (details.related.isNotEmpty)
                  SliverToBoxAdapter(child: _buildRelated(details.related)),
              ],
              SliverToBoxAdapter(
                child: SizedBox(height: tokens.spacing.section),
              ),
            ],
          ));
        },
      ),
    );
  }

  Widget _buildHero(VideoDiscoveryItem item) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final ImageProvider? backdrop = _networkImage(item.backdropUrl);
    final double width = MediaQuery.sizeOf(context).width;
    final bool compact = width < 700;
    final double expandedHeight = compact ? 460 : 430;
    return SliverAppBar(
      pinned: true,
      expandedHeight: expandedHeight,
      backgroundColor: tokens.surfaces.page,
      surfaceTintColor: Colors.transparent,
      leading: const BackButton(),
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (backdrop != null)
              LandscapeCoverImage(
                image: backdrop,
                foregroundAlignment: AlignmentDirectional.centerEnd,
                overlays: <Widget>[
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: AlignmentDirectional.centerStart,
                        end: AlignmentDirectional.centerEnd,
                        colors: <Color>[
                          tokens.surfaces.page.withValues(alpha: 0.96),
                          tokens.surfaces.page.withValues(alpha: 0.42),
                          Colors.transparent,
                        ],
                        stops: const <double>[0, 0.62, 1],
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Colors.transparent,
                          tokens.surfaces.page.withValues(alpha: 0.96),
                        ],
                        stops: const <double>[0.5, 1],
                      ),
                    ),
                  ),
                ],
                errorBuilder: (_) => ColoredBox(color: tokens.surfaces.group),
              )
            else
              ColoredBox(color: tokens.surfaces.group),
            SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  compact ? 76 : 88,
                  tokens.spacing.page,
                  tokens.spacing.page,
                ),
                child: Align(
                  alignment: AlignmentDirectional.bottomStart,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: compact ? 620 : 760),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.reference.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        if (item.reference.originalTitle?.trim().isNotEmpty ==
                            true) ...<Widget>[
                          SizedBox(height: tokens.spacing.gap / 2),
                          Text(
                            item.reference.originalTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.type.listSubtitle,
                          ),
                        ],
                        SizedBox(height: tokens.spacing.gap),
                        Text(
                          _metadataLine(item),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.type.listSubtitle,
                        ),
                        if (item.score != null) ...<Widget>[
                          SizedBox(height: tokens.spacing.gap),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.star_rounded,
                                size: 20,
                                color: colors.tertiary,
                              ),
                              SizedBox(width: tokens.spacing.gap / 2),
                              Text(
                                item.score!.toStringAsFixed(1),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ],
                        SizedBox(height: tokens.spacing.card),
                        _buildAcquisition(item),
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

  Widget _buildAcquisition(VideoDiscoveryItem item) {
    return StreamBuilder<VideoDiscoveryAcquisitionState>(
      stream: _statusStream,
      initialData: const VideoDiscoveryAcquisitionState(),
      builder: (
        BuildContext context,
        AsyncSnapshot<VideoDiscoveryAcquisitionState> snapshot,
      ) {
        final VideoDiscoveryAcquisitionState state =
            snapshot.data ?? const VideoDiscoveryAcquisitionState();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildActions(item, state),
            SizedBox(height: FushiDesignTokens.of(context).spacing.gap),
            _buildAcquisitionStatus(state),
          ],
        );
      },
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
        OutlinedButton.icon(
          key: const ValueKey<String>(
            'video-discovery-search-resource',
          ),
          onPressed: widget.actions.onSearchResource == null || state.isBusy
              ? null
              : () => unawaited(
                    widget.actions.onSearchResource!(context, item),
                  ),
          icon: const Icon(Icons.search_rounded),
          label: Text(t.video_discovery_resource_search),
        ),
        OutlinedButton.icon(
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
          icon: const Icon(Icons.subtitles_outlined),
          label: Text(t.video_discovery_subtitle_search),
        ),
        FilledButton.tonalIcon(
          key: const ValueKey<String>('video-discovery-subscribe'),
          onPressed: state.isBusy
              ? null
              : state.isSubscribed && widget.actions.onOpenSubscriptions != null
                  ? widget.actions.onOpenSubscriptions
                  : widget.actions.onSubscribe == null
                      ? null
                      : () => unawaited(
                            widget.actions.onSubscribe!(context, item),
                          ),
          icon: Icon(
            state.isSubscribed
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
          ),
          label: Text(
            state.isSubscribed
                ? t.video_discovery_subscription_manage
                : t.video_discovery_subscribe,
          ),
        ),
        if (state.isInLibrary && widget.actions.onPlay != null)
          FilledButton.icon(
            key: const ValueKey<String>('video-discovery-play'),
            onPressed: state.isBusy
                ? null
                : () => unawaited(widget.actions.onPlay!(context, item)),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(t.video_discovery_play),
          ),
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
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
        ] else
          Icon(
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

  Widget _buildDetailsError() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.page),
      child: FushiCard(
        child: Row(
          children: <Widget>[
            const Icon(Icons.cloud_off_outlined),
            SizedBox(width: tokens.spacing.gap),
            Expanded(child: Text(t.video_discovery_details_load_failed)),
            TextButton(onPressed: _retryDetails, child: Text(t.retry)),
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
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.section,
        tokens.spacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.download_detail_tab_overview,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (overview != null && overview.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            // BUG-1901：页级 SelectionArea 已让所有文本可选。这里保持普通 Text ——
            // 嵌套的 SelectableText 会自成一个独立选区，反而切断与标题/元数据的跨元素
            // 拖选，是 SelectionArea 之前遗留的逐 widget 写法。
            Text(
              overview,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
          if (details.facts.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
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
          if (details.item.genres.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap,
              children: <Widget>[
                for (final String genre in details.item.genres)
                  FushiTagChip(label: genre),
              ],
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
          Text(
            t.video_work_cast_crew,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          SizedBox(height: tokens.spacing.card),
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
                                ? const Icon(Icons.person_outline_rounded)
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
          Text(
            t.collection_related_title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          SizedBox(height: tokens.spacing.card),
          // flutter#119355：同上，相关作品条也排除在页级选区之外。这里额外多一层
          // 理由——卡片本身是点击目标（pushReplacement 进下一部作品），把它变成可
          // 拖选的文本区只会让「按下拖一下」在导航与刷选区之间摇摆。
          SelectionContainer.disabled(
            child: SizedBox(
              height: 252,
              child: HorizontalDragScrollable(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: related.length,
                  separatorBuilder: (_, __) =>
                      SizedBox(width: tokens.spacing.gap),
                  itemBuilder: (BuildContext context, int index) => SizedBox(
                    width: 132,
                    child: _RelatedWorkCard(
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
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _metadataLine(VideoDiscoveryItem item) {
    final List<String> values = <String>[
      if (item.reference.year != null) '${item.reference.year}',
      _kindLabel(item.reference.discoveryCategory),
      ...item.genres.take(3),
    ];
    return values.join(' · ');
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ImageProvider? image = _networkImage(item.posterUrl);
    final String stableId = item.reference.canonicalIdentityKey;
    return FushiCard(
      key: ValueKey<String>('video-discovery-related-$stableId'),
      padding: EdgeInsets.zero,
      focusId: FushiFocusId('video-discovery-related-$stableId'),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: image == null
                ? ColoredBox(
                    color: tokens.surfaces.group,
                    child: const Center(
                      child: Icon(Icons.movie_outlined),
                    ),
                  )
                : PortraitCoverImage(
                    image: image,
                    errorBuilder: (_) => ColoredBox(
                      color: tokens.surfaces.group,
                      child: const Center(
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: EdgeInsets.all(tokens.spacing.gap),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.reference.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle,
                ),
                Text(
                  _relatedMetadata(item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ],
            ),
          ),
        ],
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
  return value.isEmpty ? null : CachedNetworkImageProvider(value);
}
