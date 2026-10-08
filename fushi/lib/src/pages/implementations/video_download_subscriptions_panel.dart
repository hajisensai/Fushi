import 'dart:convert';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeInset;
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
import 'package:fushi/src/pages/implementations/remote_subscriptions_section.dart';
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
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.download_subscription_delete,
      message: t.download_subscription_delete_confirm(
        title: subscription.title,
      ),
      icon: FushiIcons.delete,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
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
        FushiSnackBar(content: Text(t.download_no_managed_video_source)),
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
    // 改了目标来源时，该订阅已派出、还没进整理的任务一起改过去（BUG-2755），
    // 否则它们下载完照旧整理进旧来源。
    await appModel.database.updateVideoDownloadSubscriptionRetargetingJobs(
      subscription.subscriptionId,
      VideoDownloadSubscriptionsCompanion(
        searchQuery: Value<String>(result.searchQuery),
        startAfterEpisode: Value<int?>(result.startAfterEpisode),
        subtitlePolicy: Value<String>(result.subtitlePolicy.name),
        // 用户没动过目标来源就**不写这一列**（result.targetSourceId 为 null）。
        // 无条件写会在原绑定当前不可用时把它改写成别的库，见
        // [VideoDownloadSubscriptionEdit.targetSourceId] 的说明。
        targetSourceId: result.targetSourceId == null
            ? const Value<int?>.absent()
            : Value<int?>(result.targetSourceId),
        nextCheckAt: Value<int?>(now),
        lastError: const Value<String?>(null),
        updatedAt: Value<int>(now),
      ),
      nowAt: now,
    );
    // 已完成的集还在旧来源里做种：一并摘掉种子（不删文件），否则用户删掉旧目录后
    // 引擎续传会在原处重下（BUG-2776）。
    if (result.targetSourceId != null) {
      await appModel.videoDownloadPipelineService
          ?.releaseSubscriptionSeedsOutsideTarget(subscription.subscriptionId);
    }
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
            icon: FushiIcons.error,
            title: t.error_load_failed,
          );
        }
        if (!snapshot.hasData) {
          return const FushiLoadingView();
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
          remoteSection: const RemoteSubscriptionsSection(),
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
    this.remoteSection,
    super.key,
  });

  final List<VideoDownloadSubscriptionRow> subscriptions;

  /// 已配对 host 上的订阅（host 自己跑的那些），挂在本地列表上方；null = 不显示。
  final Widget? remoteSection;
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        0,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: FushiSearchBar(
              fieldKey: const ValueKey<String>('video-subscription-search'),
              controller: _searchController,
              focusNode: _searchFocusNode,
              hintText: t.subscription_search_hint,
              onQueryChanged: (String value) =>
                  setState(() => _searchQuery = value),
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
            child: FushiOutlinedButton.icon(
              // 外层菜单接管点击；onPressed 必须为 null 才不吞菜单手势。
              onPressed: null,
              // 菜单触发器：布局边界即可视胶囊，状态层与胶囊同形。
              style: kFushiMenuTriggerButtonStyle,
              icon: const FushiIcon(FushiIcons.sort, size: 18),
              label: Text(_sortLabel(_sort)),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部汇总：订阅数 Display 大数字 + 启用数 + 说明 + 「全部检查」。
  Widget _buildHeader() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final int enabled = widget.subscriptions
        .where((VideoDownloadSubscriptionRow row) => row.enabled)
        .length;
    final Color? onContainer =
        fushiCardToneColors(context, FushiCardTone.secondary)?.onContainer;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        4,
      ),
      child: FushiCard(
        key: const ValueKey<String>('video-subscriptions-header'),
        tone: FushiCardTone.secondary,
        padding: const EdgeInsets.all(20),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 12,
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const FushiListLeadingIcon(
                    FushiIcons.notifications,
                    shape: FushiLeadingShape.cookie,
                    tone: FushiCardTone.primary,
                    size: 48,
                  ),
                  const SizedBox(width: 16),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          t.download_subscription_summary(
                            n: widget.subscriptions.length,
                            enabled: enabled,
                          ),
                          style: type.titleMediumEmphasized.tabular.copyWith(
                            color: onContainer,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t.download_subscription_running_hint,
                          style: type.bodySmall.copyWith(color: onContainer),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            FushiFilledButton.icon(
              key: const ValueKey<String>('video-subscription-check-all'),
              onPressed:
                  widget.checkingAll || enabled == 0 ? null : widget.onCheckAll,
              icon: widget.checkingAll
                  ? const SizedBox.square(
                      dimension: 16,
                      child: FushiCircularProgressIndicator(strokeWidth: 2),
                    )
                  : const FushiIcon(FushiIcons.refresh, size: 18),
              label: Text(t.download_subscription_check_all),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(VideoDownloadSubscriptionRow subscription) {
    final bool busy = _busy.contains(subscription.subscriptionId);
    return _VideoDownloadSubscriptionCard(
      key: ValueKey<String>(
        'video-subscription-card-${subscription.subscriptionId}',
      ),
      subscription: subscription,
      busy: busy,
      itemCounts:
          _itemCounts[subscription.subscriptionId] ?? const <String, int>{},
      expanded: _expanded.contains(subscription.subscriptionId),
      itemsWatcher: widget.itemsWatcher,
      onToggleExpanded: widget.itemsWatcher == null
          ? null
          : () => setState(() {
                if (!_expanded.add(subscription.subscriptionId)) {
                  _expanded.remove(subscription.subscriptionId);
                }
              }),
      onToggle: (bool enabled) =>
          _run(subscription, () => widget.onToggle(subscription, enabled)),
      onCheck: subscription.enabled
          ? () => _run(subscription, () => widget.onCheck(subscription))
          : null,
      onEdit: widget.onEdit == null
          ? null
          : () => _run(subscription, () => widget.onEdit!(subscription)),
      onDelete: () => _run(subscription, () => widget.onDelete(subscription)),
    );
  }

  /// 宽于此值时订阅卡两列网格。
  static const double _kGridBreakpoint = 900;

  @override
  Widget build(BuildContext context) {
    final List<VideoDownloadSubscriptionRow> visible =
        sortedVideoDownloadSubscriptions(
      filterVideoDownloadSubscriptions(widget.subscriptions, _searchQuery),
      _sort,
    );
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double page = tokens.spacing.page;
    final double gap = tokens.spacing.gap;
    // 叠放的浮动头部（浏览页一二级页签行）让出的高度：整页是一个滚动视图，
    // 顶部自己占位，汇总 / 搜索 / 卡片都滚到头部之下（BUG-2975）。
    final double chromeInset = FushiFloatingChromeInset.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= _kGridBreakpoint ? 2 : 1;
        final int rowCount = (visible.length + columns - 1) ~/ columns;
        final Widget body;
        if (widget.subscriptions.isEmpty || visible.isEmpty) {
          body = SliverFillRemaining(
            hasScrollBody: false,
            child: widget.subscriptions.isEmpty
                ? _VideoDownloadSubscriptionMessage(
                    icon: FushiIcons.notifications,
                    title: t.download_subscription_empty_title,
                    body: t.download_subscription_empty_body,
                  )
                : _VideoDownloadSubscriptionMessage(
                    icon: FushiIcons.searchOff,
                    title: t.subscription_no_match,
                  ),
          );
        } else {
          body = SliverPadding(
            padding: EdgeInsets.fromLTRB(page, gap, page, 24),
            sliver: SliverList.builder(
              itemCount: rowCount,
              itemBuilder: fushiStaggeredItemBuilder((
                BuildContext context,
                int row,
              ) {
                final int start = row * columns;
                final Widget content = columns == 1
                    ? _buildCard(visible[start])
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          for (int c = 0; c < columns; c++) ...<Widget>[
                            if (c > 0) SizedBox(width: gap + 4),
                            Expanded(
                              child: start + c < visible.length
                                  ? _buildCard(visible[start + c])
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      );
                return Padding(
                  padding: EdgeInsets.only(bottom: gap + 4),
                  child: content,
                );
              }),
            ),
          );
        }
        return FushiEntranceScope(
          replayKey: _sort,
          child: FushiRefreshIndicator(
            onRefresh: widget.onCheckAll,
            child: CustomScrollView(
              slivers: <Widget>[
                SliverToBoxAdapter(child: SizedBox(height: chromeInset)),
                SliverToBoxAdapter(child: _buildHeader()),
                if (widget.remoteSection != null)
                  SliverToBoxAdapter(child: widget.remoteSection),
                if (widget.subscriptions.isNotEmpty)
                  SliverToBoxAdapter(child: _buildToolbar()),
                body,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 订阅卡上的一枚信息 chip（调度 / 模式 / 来源）。
class _SubscriptionChip extends StatelessWidget {
  const _SubscriptionChip({
    required this.icon,
    required this.label,
    this.tone,
  });

  final IconData icon;
  final String label;

  /// null = 中性 surfaceContainerHigh；给了就是该色调的饱和色块。
  final FushiCardTone? tone;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final FushiCardColors? toned =
        tone == null ? null : fushiCardToneColors(context, tone!);
    final Color background = toned?.container ??
        (glass ? appleColorsOf(context).fill : cs.surfaceContainerHigh);
    final Color foreground = toned?.onContainer ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: FushiM3eShape.smallRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(icon, size: 14, color: foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.labelMedium.tabular.copyWith(
                color: foreground,
              ),
            ),
          ),
        ],
      ),
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

  Widget _buildCover(BuildContext context) {
    const double width = 56;
    const double height = 84;
    final String url = subscription.coverUrl?.trim() ?? '';
    final Widget placeholder = ColoredBox(
      color: FushiDesignTokens.of(context).surfaces.group,
      child: const Center(
        child: FushiIcon(FushiIcons.video, size: 24),
      ),
    );
    final FushiMotionScheme motion = context.fushiMotion;
    // 停用的订阅封面降饱和（透明度走 effects 弹簧，不过冲）。
    return AnimatedOpacity(
      opacity: subscription.enabled ? 1 : 0.45,
      duration: motion.effectsDefault.duration,
      curve: motion.effectsDefault.curve,
      child: ClipRRect(
        borderRadius: FushiM3eShape.smallRadius,
        child: SizedBox(
          width: width,
          height: height,
          // 与放送日历同一处理：占位底色走设计令牌，且 errorBuilder 必须给 ——
          // PortraitCoverImage 加载失败会返回 SizedBox.shrink()，不给就是封面
          // 404 / 断网留一个空洞。
          child: url.isEmpty
              ? placeholder
              : PortraitCoverImage(
                  image: AppCachedHttpImage(url),
                  errorBuilder: (_) => placeholder,
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
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
    final int failed =
        itemCounts[VideoDownloadSubscriptionItemStatus.failed] ?? 0;
    final String? lastError = subscription.lastError?.trim();
    final Widget history = expanded && itemsWatcher != null
        ? _SubscriptionItemsSection(
            subscription: subscription,
            itemsWatcher: itemsWatcher!,
          )
        : const SizedBox(width: double.infinity);
    return FushiCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildCover(context),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: type.titleMediumEmphasized,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      <String>[
                        mediaLabel,
                        subscription.resourceProvider,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodySmall.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 调度 chip：模式、下次检查（启用时）、上次检查、最近匹配、起始集。
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        _SubscriptionChip(
                          icon: subscription.mode == 'oneShot'
                              ? FushiIcons.download
                              : FushiIcons.repeat,
                          label: modeLabel,
                          tone: subscription.enabled
                              ? FushiCardTone.primary
                              : null,
                        ),
                        if (subscription.enabled &&
                            subscription.nextCheckAt != null)
                          _SubscriptionChip(
                            icon: FushiIcons.schedule,
                            label: t.subscription_next_check(
                              time: _formatTime(subscription.nextCheckAt),
                            ),
                          ),
                        _SubscriptionChip(
                          icon: FushiIcons.history,
                          label: t.download_subscription_last_checked(
                            time: _formatTime(subscription.lastCheckedAt),
                          ),
                        ),
                        if (subscription.lastMatchedAt != null)
                          _SubscriptionChip(
                            icon: FushiIcons.downloadDone,
                            label: t.subscription_last_matched(
                              time: _formatTime(subscription.lastMatchedAt),
                            ),
                            tone: FushiCardTone.tertiary,
                          ),
                        if (subscription.startAfterEpisode != null)
                          _SubscriptionChip(
                            icon: FushiIcons.skipNext,
                            label: t.download_subscription_start_episode(
                              episode: subscription.startAfterEpisode!,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                children: <Widget>[
                  FushiSwitch.adaptive(
                    key: ValueKey<String>(
                      'video-subscription-toggle-${subscription.subscriptionId}',
                    ),
                    value: subscription.enabled,
                    onChanged: busy ? null : onToggle,
                  ),
                  // 失败集数徽标：有集失败时在开关下方给一枚 error 色计数。
                  if (failed > 0) ...<Widget>[
                    const SizedBox(height: 8),
                    Container(
                      key: ValueKey<String>(
                        'video-subscription-failed-${subscription.subscriptionId}',
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: ShapeDecoration(
                        color: cs.error,
                        shape: const StadiumBorder(),
                      ),
                      child: Text(
                        '$failed',
                        style: type.labelSmallEmphasized.tabular.copyWith(
                          color: cs.onError,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          if (strictParts.isNotEmpty || _isLegacy) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              t.subscription_rules_title,
              style: type.labelMediumEmphasized.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                if (_isLegacy)
                  FushiTagChip(
                    label: t.subscription_legacy_badge,
                    color: cs.tertiary,
                    selected: true,
                    tone: FushiTagChipTone.surface,
                  ),
                for (final String part in strictParts)
                  FushiTagChip(label: part, tone: FushiTagChipTone.surface),
              ],
            ),
          ],
          if (countsLine.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              countsLine,
              key: ValueKey<String>(
                'video-subscription-items-${subscription.subscriptionId}',
              ),
              style: type.labelMedium.tabular.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
          if (_isLegacy) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              t.subscription_legacy_hint,
              style: type.bodySmall.copyWith(color: cs.onSurfaceVariant),
            ),
          ] else if (lastError != null && lastError.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            // 出错：error tonal 色块内联（共享提示横幅，不再只是一行红字）。
            FushiInlineNotice(
              severity: FushiNoticeSeverity.error,
              icon: FushiIcons.error,
              message: Text(
                lastError,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              if (onToggleExpanded != null)
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FushiTextButton.icon(
                      key: ValueKey<String>(
                        'video-subscription-expand-${subscription.subscriptionId}',
                      ),
                      onPressed: onToggleExpanded,
                      icon: AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: motion.spatialFast.duration,
                        curve: motion.spatialFast.curve,
                        child: const FushiIcon(FushiIcons.expandMore, size: 18),
                      ),
                      label: Text(
                        t.subscription_show_items,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                )
              else
                const Spacer(),
              if (onEdit != null && !_isLegacy)
                FushiIconButton(
                  key: ValueKey<String>(
                    'video-subscription-edit-${subscription.subscriptionId}',
                  ),
                  tooltip: t.subscription_edit_title,
                  icon: FushiIcons.edit,
                  onTap: busy ? null : onEdit,
                ),
              // legacy 行不给「立即检查」：新调度器对它恒报配置错误，按钮只会
              // 制造一条新的红字。
              if (!_isLegacy)
                FushiIconButton(
                  key: ValueKey<String>(
                    'video-subscription-check-${subscription.subscriptionId}',
                  ),
                  tooltip: t.download_subscription_check_now,
                  icon: FushiIcons.refresh,
                  onTap: busy ? null : onCheck,
                ),
              FushiIconButton(
                key: ValueKey<String>(
                  'video-subscription-delete-${subscription.subscriptionId}',
                ),
                tooltip: t.download_subscription_delete,
                icon: FushiIcons.delete,
                enabledColor: cs.error,
                onTap: busy ? null : onDelete,
              ),
            ],
          ),
          // 逐集历史：spatial 弹簧撑开 / 收起。降级（墨水屏 / 减弱动态效果）时
          // duration 为零，直接换子树：零时长的 RenderAnimatedSize 会在自己的
          // performLayout 里同步走完动画并 markNeedsLayout 自己。
          if (motion.spatialDefault.duration == Duration.zero)
            history
          else
            AnimatedSize(
              duration: motion.spatialDefault.duration,
              curve: motion.spatialDefault.curve,
              alignment: Alignment.topCenter,
              child: history,
            ),
        ],
      ),
    );
  }
}

/// 卡内逐集状态视图：接 `watchVideoDownloadSubscriptionItems`，每个逻辑集
/// 一行（`S01E05` / `movie`），显示发布名、状态与错误。历史即 items 表——
/// 换发布组重订也不清（窄合并纪律的另一半）。M3E 分段列表（组首尾大圆角、
/// 中间小圆角），行首状态色块。
class _SubscriptionItemsSection extends StatelessWidget {
  const _SubscriptionItemsSection({
    required this.subscription,
    required this.itemsWatcher,
  });

  final VideoDownloadSubscriptionRow subscription;
  final VideoDownloadSubscriptionItemsWatcher itemsWatcher;

  /// 这条追更订阅已经查过、却一条发布都没跟踪到。
  ///
  /// 空列表本身有两种完全不同的成因——「番还没更新」和「规则结构上对不上」——
  /// 而界面原先对两者说同一句话，用户无从分辨（BUG-2619）。查过至少一次仍为空
  /// 时补一句可操作的解释：追更只认新的单集，完结作品与整包要走一次性下载。
  bool get _ongoingNeverMatched =>
      subscription.mode == 'ongoing' &&
      subscription.lastCheckedAt != null &&
      subscription.lastMatchedAt == null;

  static FushiCardTone _toneOf(String status) => switch (status) {
        VideoDownloadSubscriptionItemStatus.processed => FushiCardTone.tertiary,
        VideoDownloadSubscriptionItemStatus.queued => FushiCardTone.primary,
        VideoDownloadSubscriptionItemStatus.failed => FushiCardTone.error,
        _ => FushiCardTone.secondary,
      };

  static IconData _iconOf(String status) => switch (status) {
        VideoDownloadSubscriptionItemStatus.processed => FushiIcons.success,
        VideoDownloadSubscriptionItemStatus.queued => FushiIcons.downloading,
        VideoDownloadSubscriptionItemStatus.failed => FushiIcons.error,
        VideoDownloadSubscriptionItemStatus.skipped => FushiIcons.block,
        _ => FushiIcons.schedule,
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiTypography type = context.fushiType;
    return StreamBuilder<List<VideoDownloadSubscriptionItemRow>>(
      stream: itemsWatcher(subscription.subscriptionId),
      builder: (
        BuildContext context,
        AsyncSnapshot<List<VideoDownloadSubscriptionItemRow>> snapshot,
      ) {
        if (!snapshot.hasData) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: FushiSkeletonShimmer(
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < 2; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: <Widget>[
                          const FushiSkeleton(width: 32, height: 32),
                          const SizedBox(width: 12),
                          Expanded(child: FushiSkeleton.line(widthFactor: 0.6)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        final List<VideoDownloadSubscriptionItemRow> items = snapshot.data!;
        final Widget heading = Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Text(
            t.subscription_history_title,
            style: type.labelMediumEmphasized.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
        if (items.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              heading,
              Text(
                t.subscription_items_empty,
                style: type.bodySmall.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_ongoingNeverMatched) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  key: const ValueKey<String>(
                    'video-subscription-never-matched-hint',
                  ),
                  t.subscription_items_empty_ongoing_hint,
                  style: type.bodySmall.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 4),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            heading,
            FushiGroupedList(
              children: <Widget>[
                for (final VideoDownloadSubscriptionItemRow item in items)
                  FushiListItem(
                    key: ValueKey<String>(
                      'video-subscription-item-${item.id}',
                    ),
                    density: FushiListDensity.compact,
                    leading: FushiListLeadingIcon(
                      _iconOf(item.status),
                      shape: FushiLeadingShape.square,
                      tone: _toneOf(item.status),
                      size: 32,
                      iconSize: 18,
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

  /// 走共享空状态：M3E 是色块图标 + 弹入，Apple 是 ContentUnavailableView 形态。
  @override
  Widget build(BuildContext context) {
    return FushiPlaceholderMessage(icon: icon, message: title, detail: body);
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
