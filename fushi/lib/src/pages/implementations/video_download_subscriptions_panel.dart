import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        MediaSourceRow,
        VideoDownloadSubscriptionItemRow,
        VideoDownloadSubscriptionItemStatus,
        VideoDownloadSubscriptionRow,
        VideoDownloadSubscriptionsCompanion;

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_download_subscription_edit_dialog.dart';
import 'package:fushi/utils.dart';

typedef VideoDownloadSubscriptionAction = Future<void> Function(
  VideoDownloadSubscriptionRow subscription,
);

typedef VideoDownloadSubscriptionToggle = Future<void> Function(
  VideoDownloadSubscriptionRow subscription,
  bool enabled,
);

/// 订阅逐集历史的窄读端口（面板卡片展开时接 DB stream；测试可注入假流）。
typedef VideoDownloadSubscriptionItemsWatcher
    = Stream<List<VideoDownloadSubscriptionItemRow>> Function(
  String subscriptionId,
);

/// 订阅列表的排序维度（会话级）。
enum VideoDownloadSubscriptionSort {
  createdDesc,
  titleAsc,
  lastCheckedDesc,
  lastMatchedDesc,
}

/// 搜索过滤：标题与搜索词任一命中即留（库页同一套归一化口径）。纯函数。
List<VideoDownloadSubscriptionRow> filterVideoDownloadSubscriptions(
  List<VideoDownloadSubscriptionRow> subscriptions,
  String query,
) =>
    filterByMediaSearch(
      subscriptions,
      query,
      (VideoDownloadSubscriptionRow row) =>
          <String>[row.title, row.searchQuery],
    );

/// 按 [sort] 返回新的有序列表。纯函数，稳定 tiebreak createdAt 倒序 + id。
List<VideoDownloadSubscriptionRow> sortedVideoDownloadSubscriptions(
  List<VideoDownloadSubscriptionRow> subscriptions,
  VideoDownloadSubscriptionSort sort,
) {
  int byCreatedDesc(
    VideoDownloadSubscriptionRow a,
    VideoDownloadSubscriptionRow b,
  ) {
    final int byCreated = b.createdAt.compareTo(a.createdAt);
    return byCreated != 0
        ? byCreated
        : a.subscriptionId.compareTo(b.subscriptionId);
  }

  int byNullableDesc(int? a, int? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return b.compareTo(a);
  }

  final List<VideoDownloadSubscriptionRow> out =
      List<VideoDownloadSubscriptionRow>.of(subscriptions);
  switch (sort) {
    case VideoDownloadSubscriptionSort.createdDesc:
      out.sort(byCreatedDesc);
    case VideoDownloadSubscriptionSort.titleAsc:
      out.sort(
          (VideoDownloadSubscriptionRow a, VideoDownloadSubscriptionRow b) {
        final int byTitle =
            a.title.toLowerCase().compareTo(b.title.toLowerCase());
        return byTitle != 0 ? byTitle : byCreatedDesc(a, b);
      });
    case VideoDownloadSubscriptionSort.lastCheckedDesc:
      out.sort(
          (VideoDownloadSubscriptionRow a, VideoDownloadSubscriptionRow b) {
        final int byChecked = byNullableDesc(a.lastCheckedAt, b.lastCheckedAt);
        return byChecked != 0 ? byChecked : byCreatedDesc(a, b);
      });
    case VideoDownloadSubscriptionSort.lastMatchedDesc:
      out.sort(
          (VideoDownloadSubscriptionRow a, VideoDownloadSubscriptionRow b) {
        final int byMatched = byNullableDesc(a.lastMatchedAt, b.lastMatchedAt);
        return byMatched != 0 ? byMatched : byCreatedDesc(a, b);
      });
  }
  return out;
}

/// Schema-v78 订阅真相源的管理面板。旧 JSON 只由一次性 importer 读取，页面不再
/// 直接管理它，避免用户在两套互不一致的订阅状态之间切换。
///
/// 2026-08 重做（B3，参照 RSS-Subtitle-Manager）：卡片富信息化（封面/调度/
/// 逐集计数）、编辑走窄合并（[showVideoDownloadSubscriptionEditDialog] +
/// `updateVideoDownloadSubscription` 白名单列，items 历史绝不清）、卡内逐集
/// 状态视图、搜索 + 排序。
class VideoDownloadSubscriptionsPanel extends ConsumerStatefulWidget {
  const VideoDownloadSubscriptionsPanel({super.key});

  @override
  ConsumerState<VideoDownloadSubscriptionsPanel> createState() =>
      _VideoDownloadSubscriptionsPanelState();
}

class _VideoDownloadSubscriptionsPanelState
    extends ConsumerState<VideoDownloadSubscriptionsPanel> {
  bool _checkingAll = false;

  Future<void> _setEnabled(
    VideoDownloadSubscriptionRow subscription,
    bool enabled,
  ) async {
    final AppModel appModel = ref.read(appProvider);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await appModel.database.updateVideoDownloadSubscription(
      subscription.subscriptionId,
      VideoDownloadSubscriptionsCompanion(
        enabled: Value<bool>(enabled),
        nextCheckAt: enabled ? Value<int?>(now) : const Value<int?>.absent(),
        // oneShot 完成位只在 disabled 态合法（表级 CHECK）；重新启用必须同时
        // 清掉，否则写入直接抛。
        fulfilledAt:
            enabled ? const Value<int?>(null) : const Value<int?>.absent(),
        updatedAt: Value<int>(now),
      ),
    );
    if (enabled) {
      await appModel.videoDownloadSubscriptionService?.checkNow();
    }
  }

  Future<void> _checkOne(
    VideoDownloadSubscriptionRow subscription,
  ) async {
    if (!subscription.enabled) return;
    final AppModel appModel = ref.read(appProvider);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await appModel.database.updateVideoDownloadSubscription(
      subscription.subscriptionId,
      VideoDownloadSubscriptionsCompanion(
        nextCheckAt: Value<int?>(now),
        updatedAt: Value<int>(now),
      ),
    );
    await appModel.videoDownloadSubscriptionService?.checkNow();
  }

  Future<void> _checkAll(
    List<VideoDownloadSubscriptionRow> subscriptions,
  ) async {
    if (_checkingAll) return;
    setState(() => _checkingAll = true);
    try {
      final AppModel appModel = ref.read(appProvider);
      final int now = DateTime.now().millisecondsSinceEpoch;
      for (final VideoDownloadSubscriptionRow subscription
          in subscriptions.where(
        (VideoDownloadSubscriptionRow row) => row.enabled,
      )) {
        await appModel.database.updateVideoDownloadSubscription(
          subscription.subscriptionId,
          VideoDownloadSubscriptionsCompanion(
            nextCheckAt: Value<int?>(now),
            updatedAt: Value<int>(now),
          ),
        );
      }
      await appModel.videoDownloadSubscriptionService?.checkNow();
    } finally {
      if (mounted) setState(() => _checkingAll = false);
    }
  }

  Future<void> _delete(
    VideoDownloadSubscriptionRow subscription,
  ) async {
    final bool confirmed = await showAppDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: Text(t.download_subscription_delete),
            content: Text(
              t.download_subscription_delete_confirm(
                title: subscription.title,
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(t.dialog_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(t.dialog_delete),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await ref
        .read(appProvider)
        .database
        .deleteVideoDownloadSubscription(subscription.subscriptionId);
  }

  /// 编辑订阅（窄合并）：只写白名单列（搜索词 / 起始集 / 字幕策略 / 目标
  /// 来源）+ `nextCheckAt=now` 让新规则尽快跑一轮 + 清 `lastError`。
  /// items 历史与调度状态其余字段一概不动——「改规则不清历史」。
  Future<void> _edit(VideoDownloadSubscriptionRow subscription) async {
    final AppModel appModel = ref.read(appProvider);
    final List<MediaSourceRow> sources =
        await appModel.getManagedVideoDownloadSources();
    if (!mounted) return;
    if (sources.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(t.download_no_managed_video_source)),
      );
      return;
    }
    final VideoDownloadSubscriptionEdit? result =
        await showVideoDownloadSubscriptionEditDialog(
      context: context,
      subscription: subscription,
      sources: sources,
    );
    if (result == null || !mounted) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await appModel.database.updateVideoDownloadSubscription(
      subscription.subscriptionId,
      VideoDownloadSubscriptionsCompanion(
        searchQuery: Value<String>(result.searchQuery),
        startAfterEpisode: Value<int?>(result.startAfterEpisode),
        subtitlePolicy: Value<String>(result.subtitlePolicy.name),
        targetSourceId: Value<int?>(result.targetSourceId),
        nextCheckAt: Value<int?>(now),
        lastError: const Value<String?>(null),
        updatedAt: Value<int>(now),
      ),
    );
    await appModel.videoDownloadSubscriptionService?.checkNow();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDatabase database = ref.read(appProvider).database;
    return StreamBuilder<List<VideoDownloadSubscriptionRow>>(
      stream: database.watchVideoDownloadSubscriptions(),
      builder: (
        BuildContext context,
        AsyncSnapshot<List<VideoDownloadSubscriptionRow>> snapshot,
      ) {
        if (snapshot.hasError) {
          return _VideoDownloadSubscriptionMessage(
            icon: Icons.error_outline,
            title: t.error_load_failed,
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final List<VideoDownloadSubscriptionRow> subscriptions = snapshot.data!;
        return VideoDownloadSubscriptionsView(
          subscriptions: subscriptions,
          checkingAll: _checkingAll,
          onCheckAll: () => _checkAll(subscriptions),
          onToggle: _setEnabled,
          onCheck: _checkOne,
          onDelete: _delete,
          onEdit: _edit,
          itemsWatcher: database.watchVideoDownloadSubscriptionItems,
          itemCountsLoader:
              database.getVideoDownloadSubscriptionItemStatusCounts,
        );
      },
    );
  }
}

/// 可注入动作的纯 UI，方便窄屏和交互测试不依赖完整 [AppModel]。
class VideoDownloadSubscriptionsView extends StatefulWidget {
  const VideoDownloadSubscriptionsView({
    required this.subscriptions,
    required this.checkingAll,
    required this.onCheckAll,
    required this.onToggle,
    required this.onCheck,
    required this.onDelete,
    this.onEdit,
    this.itemsWatcher,
    this.itemCountsLoader,
    super.key,
  });

  final List<VideoDownloadSubscriptionRow> subscriptions;
  final bool checkingAll;
  final Future<void> Function() onCheckAll;
  final VideoDownloadSubscriptionToggle onToggle;
  final VideoDownloadSubscriptionAction onCheck;
  final VideoDownloadSubscriptionAction onDelete;

  /// null = 宿主不支持编辑（旧测试宿主），卡片不渲染编辑入口。
  final VideoDownloadSubscriptionAction? onEdit;

  /// null = 不支持逐集视图。
  final VideoDownloadSubscriptionItemsWatcher? itemsWatcher;

  /// null = 卡片不显示逐集计数摘要。
  final Future<Map<String, Map<String, int>>> Function()? itemCountsLoader;

  @override
  State<VideoDownloadSubscriptionsView> createState() =>
      _VideoDownloadSubscriptionsViewState();
}

class _VideoDownloadSubscriptionsViewState
    extends State<VideoDownloadSubscriptionsView> {
  final Set<String> _busy = <String>{};
  final Set<String> _expanded = <String>{};
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  VideoDownloadSubscriptionSort _sort =
      VideoDownloadSubscriptionSort.createdDesc;
  Map<String, Map<String, int>> _itemCounts = <String, Map<String, int>>{};

  @override
  void initState() {
    super.initState();
    _reloadItemCounts();
  }

  @override
  void didUpdateWidget(VideoDownloadSubscriptionsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.subscriptions, widget.subscriptions)) {
      // 订阅流每次发新列表都可能伴随 items 变化（服务刚跑完一轮），跟着刷新
      // 计数；一条 GROUP BY 查询，代价可忽略。
      _reloadItemCounts();
    }
  }

  void _reloadItemCounts() {
    final Future<Map<String, Map<String, int>>> Function()? loader =
        widget.itemCountsLoader;
    if (loader == null) return;
    loader().then((Map<String, Map<String, int>> counts) {
      if (mounted) setState(() => _itemCounts = counts);
    }).catchError((Object _) {
      // 计数是增强信息，查询失败不影响订阅列表本体。
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _run(
    VideoDownloadSubscriptionRow subscription,
    Future<void> Function() action,
  ) async {
    if (_busy.contains(subscription.subscriptionId)) return;
    setState(() => _busy.add(subscription.subscriptionId));
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy.remove(subscription.subscriptionId));
    }
  }

  static String _sortLabel(VideoDownloadSubscriptionSort sort) =>
      switch (sort) {
        VideoDownloadSubscriptionSort.createdDesc =>
          t.subscription_sort_created,
        VideoDownloadSubscriptionSort.titleAsc => t.sort_title,
        VideoDownloadSubscriptionSort.lastCheckedDesc =>
          t.subscription_sort_last_checked,
        VideoDownloadSubscriptionSort.lastMatchedDesc =>
          t.subscription_sort_last_matched,
      };

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: FushiSearchField(
              fieldKey: const ValueKey<String>('video-subscription-search'),
              controller: _searchController,
              focusNode: _searchFocusNode,
              hintText: t.subscription_search_hint,
              onChanged: (String value) => setState(() => _searchQuery = value),
              onSubmitted: (String value) =>
                  setState(() => _searchQuery = value),
              onClear: () => setState(() => _searchQuery = ''),
            ),
          ),
          const SizedBox(width: 8),
          FushiOverflowMenu<VideoDownloadSubscriptionSort>(
            key: const ValueKey<String>('video-subscription-sort'),
            tooltip: t.sort_by,
            onSelected: (VideoDownloadSubscriptionSort value) =>
                setState(() => _sort = value),
            items: <PopupMenuEntry<VideoDownloadSubscriptionSort>>[
              for (final VideoDownloadSubscriptionSort value
                  in VideoDownloadSubscriptionSort.values)
                FushiPopupMenuItem<VideoDownloadSubscriptionSort>(
                  value: value,
                  label: _sortLabel(value),
                  selected: _sort == value,
                ),
            ],
            child: OutlinedButton.icon(
              // 外层菜单接管点击；onPressed 必须为 null 才不吞菜单手势。
              onPressed: null,
              icon: const Icon(Icons.sort, size: 18),
              label: Text(_sortLabel(_sort)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<VideoDownloadSubscriptionRow> visible =
        sortedVideoDownloadSubscriptions(
      filterVideoDownloadSubscriptions(widget.subscriptions, _searchQuery),
      _sort,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: FushiCard(
            key: const ValueKey<String>('video-subscriptions-header'),
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Text(
                    t.download_subscription_running_hint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey<String>(
                    'video-subscription-check-all',
                  ),
                  onPressed: widget.checkingAll ||
                          !widget.subscriptions.any(
                            (VideoDownloadSubscriptionRow row) => row.enabled,
                          )
                      ? null
                      : widget.onCheckAll,
                  icon: widget.checkingAll
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(t.download_subscription_check_all),
                ),
              ],
            ),
          ),
        ),
        if (widget.subscriptions.isNotEmpty) _buildToolbar(),
        Expanded(
          child: widget.subscriptions.isEmpty
              ? _VideoDownloadSubscriptionMessage(
                  icon: Icons.subscriptions_outlined,
                  title: t.download_subscription_empty_title,
                  body: t.download_subscription_empty_body,
                )
              : visible.isEmpty
                  ? _VideoDownloadSubscriptionMessage(
                      icon: Icons.search_off,
                      title: t.subscription_no_match,
                    )
                  : RefreshIndicator(
                      onRefresh: widget.onCheckAll,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: visible.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (BuildContext context, int index) {
                          final VideoDownloadSubscriptionRow subscription =
                              visible[index];
                          final bool busy =
                              _busy.contains(subscription.subscriptionId);
                          return _VideoDownloadSubscriptionCard(
                            key: ValueKey<String>(
                              'video-subscription-card-${subscription.subscriptionId}',
                            ),
                            subscription: subscription,
                            busy: busy,
                            itemCounts:
                                _itemCounts[subscription.subscriptionId] ??
                                    const <String, int>{},
                            expanded:
                                _expanded.contains(subscription.subscriptionId),
                            itemsWatcher: widget.itemsWatcher,
                            onToggleExpanded: widget.itemsWatcher == null
                                ? null
                                : () => setState(() {
                                      if (!_expanded
                                          .add(subscription.subscriptionId)) {
                                        _expanded.remove(
                                            subscription.subscriptionId);
                                      }
                                    }),
                            onToggle: (bool enabled) => _run(
                              subscription,
                              () => widget.onToggle(subscription, enabled),
                            ),
                            onCheck: subscription.enabled
                                ? () => _run(
                                      subscription,
                                      () => widget.onCheck(subscription),
                                    )
                                : null,
                            onEdit: widget.onEdit == null
                                ? null
                                : () => _run(
                                      subscription,
                                      () => widget.onEdit!(subscription),
                                    ),
                            onDelete: () => _run(
                              subscription,
                              () => widget.onDelete(subscription),
                            ),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }
}

class _VideoDownloadSubscriptionCard extends StatelessWidget {
  const _VideoDownloadSubscriptionCard({
    super.key,
    required this.subscription,
    required this.busy,
    required this.onToggle,
    required this.onCheck,
    required this.onDelete,
    this.onEdit,
    this.itemCounts = const <String, int>{},
    this.expanded = false,
    this.itemsWatcher,
    this.onToggleExpanded,
  });

  final VideoDownloadSubscriptionRow subscription;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onCheck;
  final VoidCallback onDelete;
  final VoidCallback? onEdit;

  /// status → count（[VideoDownloadSubscriptionItemStatus] 值域）。
  final Map<String, int> itemCounts;
  final bool expanded;
  final VideoDownloadSubscriptionItemsWatcher? itemsWatcher;
  final VoidCallback? onToggleExpanded;

  bool get _isLegacy => subscription.organizationPolicy == 'legacy';

  String _formatTime(int? milliseconds) {
    if (milliseconds == null) return t.download_subscription_never_checked;
    return FushiTimeFormat.dateHourMinute(
      DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal(),
    );
  }

  static String itemStatusLabel(String status) => switch (status) {
        VideoDownloadSubscriptionItemStatus.discovered =>
          t.subscription_item_status_discovered,
        VideoDownloadSubscriptionItemStatus.queued =>
          t.subscription_item_status_queued,
        VideoDownloadSubscriptionItemStatus.processed =>
          t.subscription_item_status_processed,
        VideoDownloadSubscriptionItemStatus.skipped =>
          t.subscription_item_status_skipped,
        VideoDownloadSubscriptionItemStatus.failed =>
          t.subscription_item_status_failed,
        _ => status,
      };

  /// 逐集计数摘要（`已入库 5 · 排队中 1 · 失败 2`）；零计数状态跳过。
  String get _itemCountsLine {
    const List<String> order = <String>[
      VideoDownloadSubscriptionItemStatus.processed,
      VideoDownloadSubscriptionItemStatus.queued,
      VideoDownloadSubscriptionItemStatus.discovered,
      VideoDownloadSubscriptionItemStatus.failed,
      VideoDownloadSubscriptionItemStatus.skipped,
    ];
    final List<String> parts = <String>[
      for (final String status in order)
        if ((itemCounts[status] ?? 0) > 0)
          '${itemStatusLabel(status)} ${itemCounts[status]}',
    ];
    return parts.join(' · ');
  }

  Widget _buildCover(ThemeData theme) {
    const double width = 40;
    const double height = 60;
    final String url = subscription.coverUrl?.trim() ?? '';
    return ClipRRect(
      borderRadius: FushiBorderRadius.chip,
      child: SizedBox(
        width: width,
        height: height,
        child: url.isEmpty
            ? ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.subscriptions_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : PortraitCoverImage(image: CachedNetworkImageProvider(url)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<String> strictParts =
        videoDownloadSubscriptionFilterSummary(subscription.filterJson);
    final String mediaLabel = subscription.mediaKind == 'movie'
        ? t.collection_relation_movie
        : t.series;
    final String modeLabel = subscription.mode == 'oneShot'
        ? t.subscription_mode_one_shot
        : t.subscription_mode_ongoing;
    final String title = subscription.year == null
        ? subscription.title
        : '${subscription.title} (${subscription.year})';
    final String countsLine = _itemCountsLine;
    return FushiCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildCover(theme),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      <String>[
                        mediaLabel,
                        subscription.resourceProvider,
                        modeLabel,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(
                key: ValueKey<String>(
                  'video-subscription-toggle-${subscription.subscriptionId}',
                ),
                value: subscription.enabled,
                onChanged: busy ? null : onToggle,
              ),
            ],
          ),
          if (strictParts.isNotEmpty || _isLegacy) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                if (_isLegacy)
                  FushiTagChip(
                    label: t.subscription_legacy_badge,
                    color: theme.colorScheme.tertiary,
                    selected: true,
                    tone: FushiTagChipTone.surface,
                  ),
                for (final String part in strictParts)
                  FushiTagChip(label: part, tone: FushiTagChipTone.surface),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            t.download_subscription_last_checked(
              time: _formatTime(subscription.lastCheckedAt),
            ),
            style: theme.textTheme.bodySmall,
          ),
          if (subscription.enabled && subscription.nextCheckAt != null)
            Text(
              t.subscription_next_check(
                time: _formatTime(subscription.nextCheckAt),
              ),
              style: theme.textTheme.bodySmall,
            ),
          if (subscription.lastMatchedAt != null)
            Text(
              t.subscription_last_matched(
                time: _formatTime(subscription.lastMatchedAt),
              ),
              style: theme.textTheme.bodySmall,
            ),
          if (subscription.startAfterEpisode != null)
            Text(
              t.download_subscription_start_episode(
                episode: subscription.startAfterEpisode!,
              ),
              style: theme.textTheme.bodySmall,
            ),
          if (countsLine.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              countsLine,
              key: ValueKey<String>(
                'video-subscription-items-${subscription.subscriptionId}',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_isLegacy) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              t.subscription_legacy_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ] else if (subscription.lastError?.trim().isNotEmpty ??
              false) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              subscription.lastError!.trim(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                if (onToggleExpanded != null)
                  FushiIconButton(
                    key: ValueKey<String>(
                      'video-subscription-expand-${subscription.subscriptionId}',
                    ),
                    tooltip: t.subscription_show_items,
                    icon: expanded ? Icons.expand_less : Icons.expand_more,
                    onTap: onToggleExpanded,
                  ),
                if (onEdit != null && !_isLegacy)
                  FushiIconButton(
                    key: ValueKey<String>(
                      'video-subscription-edit-${subscription.subscriptionId}',
                    ),
                    tooltip: t.subscription_edit_title,
                    icon: Icons.edit_outlined,
                    onTap: busy ? null : onEdit,
                  ),
                // legacy 行不给「立即检查」：新调度器对它恒报配置错误，按钮
                // 只会制造一条新的红字。
                if (!_isLegacy)
                  FushiIconButton(
                    key: ValueKey<String>(
                      'video-subscription-check-${subscription.subscriptionId}',
                    ),
                    tooltip: t.download_subscription_check_now,
                    icon: Icons.refresh,
                    onTap: busy ? null : onCheck,
                  ),
                FushiIconButton(
                  key: ValueKey<String>(
                    'video-subscription-delete-${subscription.subscriptionId}',
                  ),
                  tooltip: t.download_subscription_delete,
                  icon: Icons.delete_outline,
                  onTap: busy ? null : onDelete,
                ),
              ],
            ),
          ),
          if (expanded && itemsWatcher != null)
            _SubscriptionItemsSection(
              subscriptionId: subscription.subscriptionId,
              itemsWatcher: itemsWatcher!,
            ),
        ],
      ),
    );
  }
}

/// 卡内逐集状态视图：接 `watchVideoDownloadSubscriptionItems`，每个逻辑集
/// 一行（`S01E05` / `movie`），显示发布名、状态与错误。历史即 items 表——
/// 换发布组重订也不清（窄合并纪律的另一半）。
class _SubscriptionItemsSection extends StatelessWidget {
  const _SubscriptionItemsSection({
    required this.subscriptionId,
    required this.itemsWatcher,
  });

  final String subscriptionId;
  final VideoDownloadSubscriptionItemsWatcher itemsWatcher;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return StreamBuilder<List<VideoDownloadSubscriptionItemRow>>(
      stream: itemsWatcher(subscriptionId),
      builder: (
        BuildContext context,
        AsyncSnapshot<List<VideoDownloadSubscriptionItemRow>> snapshot,
      ) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final List<VideoDownloadSubscriptionItemRow> items = snapshot.data!;
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              t.subscription_items_empty,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SizedBox(height: 4),
            for (final VideoDownloadSubscriptionItemRow item in items)
              FushiListItem(
                key: ValueKey<String>(
                  'video-subscription-item-${item.id}',
                ),
                density: FushiListDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(
                  switch (item.status) {
                    VideoDownloadSubscriptionItemStatus.processed =>
                      Icons.check_circle_outline,
                    VideoDownloadSubscriptionItemStatus.queued =>
                      Icons.downloading_outlined,
                    VideoDownloadSubscriptionItemStatus.failed =>
                      Icons.error_outline,
                    VideoDownloadSubscriptionItemStatus.skipped =>
                      Icons.remove_circle_outline,
                    _ => Icons.schedule_outlined,
                  },
                  size: 18,
                  color: switch (item.status) {
                    VideoDownloadSubscriptionItemStatus.processed =>
                      theme.colorScheme.primary,
                    VideoDownloadSubscriptionItemStatus.failed =>
                      theme.colorScheme.error,
                    _ => theme.colorScheme.onSurfaceVariant,
                  },
                ),
                title: Text(
                  item.title,
                  maxLines: 2,
                  softWrap: true,
                  overflow: TextOverflow.fade,
                ),
                titleMaxLines: 2,
                subtitle: Text(
                  <String>[
                    item.logicalItemKey,
                    _VideoDownloadSubscriptionCard.itemStatusLabel(
                      item.status,
                    ),
                    if (item.error?.trim().isNotEmpty ?? false)
                      item.error!.trim(),
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitleMaxLines: 2,
              ),
          ],
        );
      },
    );
  }
}

class _VideoDownloadSubscriptionMessage extends StatelessWidget {
  const _VideoDownloadSubscriptionMessage({
    required this.icon,
    required this.title,
    this.body,
  });

  final IconData icon;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 44, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (body != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 将严格规则按稳定顺序转成紧凑摘要；未知字段不展示，避免未来凭据字段被误带入 UI。
/// 固定键同时接受 String 与 List（torznab 多值规则此前在 UI 上被漏显）。
List<String> videoDownloadSubscriptionFilterSummary(String rawJson) {
  try {
    final Object? decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, Object?>) return const <String>[];
    final List<String> result = <String>[];
    void addValue(Object? value) {
      if (value is String && value.trim().isNotEmpty) {
        result.add(value.trim());
      } else if (value is List<Object?>) {
        result.addAll(
          value
              .whereType<String>()
              .map((String v) => v.trim())
              .where((String v) => v.isNotEmpty),
        );
      }
    }

    for (final String key in <String>[
      'releaseGroup',
      'resolution',
      'quality',
      'source',
      'codec',
      'language',
      'category',
    ]) {
      addValue(decoded[key]);
    }
    addValue(decoded['languages']);
    final Object? trusted = decoded['trusted'] ?? decoded['trustedOnly'];
    if (trusted is bool) {
      result.add(
        trusted
            ? t.anime_download_trusted
            : '${t.anime_download_trusted}: false',
      );
    }
    return result.toSet().toList(growable: false);
  } on FormatException {
    return const <String>[];
  }
}
