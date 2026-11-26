import 'dart:async';
import 'dart:convert';

import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
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
        VideoDownloadSubscriptionRow;
import 'package:fushi_engine/sync/subscriptions/host_subscription_routes.dart'
    show HostSubscriptionRejected;
import 'package:fushi_engine/sync/subscriptions/pipeline_subscription_host.dart'
    show PipelineSubscriptionHost, VideoDownloadSubscriptionRuleEdit;

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_engine/media/video/download/video_download_subscription_auto_disable.dart';
import 'package:fushi_engine/media/video/download/video_download_subscription_service.dart'
    show
        VideoDownloadSubscriptionConfigIssue,
        isVideoSubscriptionBtSiteMissingError,
        kVideoSubscriptionCheckFailedError;
import 'package:fushi/src/pages/implementations/activity_feed.dart'
    show formatActivityRelativeTime;
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart'
    show FushiStatusTone, fushiStatusColor;
import 'package:fushi/src/pages/implementations/bt_site_settings_route.dart';
import 'package:fushi/src/pages/implementations/remote_subscriptions_section.dart';
import 'package:fushi/src/pages/implementations/video_download_subscription_edit_dialog.dart';
import 'package:fushi/src/sync/app_download_host.dart' show AppSubscriptionHost;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:fushi/src/media/downloads/apple/apple_download_list_parts.dart';
import 'package:fushi/src/media/downloads/apple/apple_download_task_row.dart'
    show appleDownloadMenuPosition;
import 'package:fushi/src/media/downloads/download_task_card.dart'
    show DownloadTaskCoverThumb;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_popup_button.dart';
import 'package:fushi/src/utils/components/apple/apple_radii.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart'
    show ContextMenuTrigger;

part '../../media/downloads/apple/apple_download_subscriptions.dart';

typedef VideoDownloadSubscriptionAction =
    Future<void> Function(VideoDownloadSubscriptionRow subscription);

typedef VideoDownloadSubscriptionToggle =
    Future<void> Function(
      VideoDownloadSubscriptionRow subscription,
      bool enabled,
    );

/// 订阅逐集历史的窄读端口（面板卡片展开时接 DB stream；测试可注入假流）。
typedef VideoDownloadSubscriptionItemsWatcher =
    Stream<List<VideoDownloadSubscriptionItemRow>> Function(
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
) => filterByMediaSearch(
  subscriptions,
  query,
  (VideoDownloadSubscriptionRow row) => <String>[row.title, row.searchQuery],
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
      out.sort((
        VideoDownloadSubscriptionRow a,
        VideoDownloadSubscriptionRow b,
      ) {
        final int byTitle = a.title.toLowerCase().compareTo(
          b.title.toLowerCase(),
        );
        return byTitle != 0 ? byTitle : byCreatedDesc(a, b);
      });
    case VideoDownloadSubscriptionSort.lastCheckedDesc:
      out.sort((
        VideoDownloadSubscriptionRow a,
        VideoDownloadSubscriptionRow b,
      ) {
        final int byChecked = byNullableDesc(a.lastCheckedAt, b.lastCheckedAt);
        return byChecked != 0 ? byChecked : byCreatedDesc(a, b);
      });
    case VideoDownloadSubscriptionSort.lastMatchedDesc:
      out.sort((
        VideoDownloadSubscriptionRow a,
        VideoDownloadSubscriptionRow b,
      ) {
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
/// [AppSubscriptionHost.update] 白名单列，items 历史绝不清）、卡内逐集
/// 状态视图、搜索 + 排序。所有写操作只经 [AppSubscriptionHost]（与桌面控制通道
/// 同一份），页面不直接写库。
class VideoDownloadSubscriptionsPanel extends ConsumerStatefulWidget {
  const VideoDownloadSubscriptionsPanel({super.key});

  @override
  ConsumerState<VideoDownloadSubscriptionsPanel> createState() =>
      _VideoDownloadSubscriptionsPanelState();
}

class _VideoDownloadSubscriptionsPanelState
    extends ConsumerState<VideoDownloadSubscriptionsPanel> {
  bool _checkingAll = false;

  /// 本机订阅操作的唯一入口（与桌面控制通道同一份，见 [AppSubscriptionHost]）。
  AppSubscriptionHost get _host =>
      ref.read(appProvider).appDownloadHost.subscriptions;

  /// host 拒绝（没有下载后端 / 订阅已停用等）→ 提示，不当成未捕获错误。
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on HostSubscriptionRejected catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        FushiSnackBar(
          content: Text(switch (e.reason) {
            'unsupported' => t.download_backend_not_configured,
            'disabled' => t.download_subscription_disabled_enable_first,
            _ => e.message,
          }),
        ),
      );
    }
  }

  int get _autoDisableDays => readVideoDownloadSubscriptionAutoDisableDays(
    ref.read(appProvider).prefsRepo,
  );

  Future<void> _setAutoDisableDays(int days) async {
    await writeVideoDownloadSubscriptionAutoDisableDays(
      ref.read(appProvider).prefsRepo,
      days,
    );
    if (mounted) setState(() {});
  }

  Future<void> _setEnabled(
    VideoDownloadSubscriptionRow subscription,
    bool enabled,
  ) => _guard(() => _host.setEnabled(subscription.subscriptionId, enabled));

  Future<void> _checkOne(VideoDownloadSubscriptionRow subscription) async {
    if (!subscription.enabled) return;
    await _guard(() => _host.checkNow(subscription.subscriptionId));
  }

  Future<void> _checkAll() async {
    if (_checkingAll) return;
    setState(() => _checkingAll = true);
    try {
      await _guard(() => _host.checkNow(null));
    } finally {
      if (mounted) setState(() => _checkingAll = false);
    }
  }

  Future<void> _delete(VideoDownloadSubscriptionRow subscription) async {
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
    await _guard(() => _host.delete(subscription.subscriptionId));
  }

  /// 编辑订阅（窄合并，见 [PipelineSubscriptionHost.update]）：只写白名单列（搜索词 /
  /// 起始集 / 字幕策略 / 目标来源 / 版本规则），items 历史与其余调度状态一概不动——
  /// 「改规则不清历史」。
  Future<void> _edit(VideoDownloadSubscriptionRow subscription) async {
    final AppModel appModel = ref.read(appProvider);
    final List<MediaSourceRow> sources = await appModel
        .getManagedVideoDownloadSources();
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
    await _guard(
      () => _host.update(
        subscription.subscriptionId,
        VideoDownloadSubscriptionRuleEdit(
          searchQuery: Value<String>(result.searchQuery),
          startAfterEpisode: Value<int?>(result.startAfterEpisode),
          subtitlePolicy: Value<String>(result.subtitlePolicy.name),
          // 用户没动过目标来源就**不写这一列**（result.targetSourceId 为 null）。
          // 无条件写会在原绑定当前不可用时把它改写成别的库，见
          // [VideoDownloadSubscriptionEdit.targetSourceId] 的说明。
          targetSourceId: result.targetSourceId == null
              ? const Value<int?>.absent()
              : Value<int?>(result.targetSourceId),
          // 字幕组 / 分辨率 / 标题关键词：同样只在用户改过时写（null = 没动）。
          filterJson: result.filterJson == null
              ? const Value<String>.absent()
              : Value<String>(result.filterJson!),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDatabase database = ref.read(appProvider).database;
    return StreamBuilder<List<VideoDownloadSubscriptionRow>>(
      stream: database.watchVideoDownloadSubscriptions(),
      builder:
          (
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
            final List<VideoDownloadSubscriptionRow> subscriptions =
                snapshot.data!;
            return VideoDownloadSubscriptionsView(
              subscriptions: subscriptions,
              checkingAll: _checkingAll,
              onCheckAll: _checkAll,
              onToggle: _setEnabled,
              onCheck: _checkOne,
              onDelete: _delete,
              onEdit: _edit,
              autoDisableDays: _autoDisableDays,
              onAutoDisableDaysChanged: _setAutoDisableDays,
              itemsWatcher: database.watchVideoDownloadSubscriptionItems,
              itemCountsLoader:
                  database.getVideoDownloadSubscriptionItemStatusCounts,
              latestDiscoveredLoader:
                  database.getVideoDownloadSubscriptionLatestDiscoveredAt,
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
    this.autoDisableDays = 0,
    this.onAutoDisableDaysChanged,
    this.latestDiscoveredLoader,
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

  /// 追更订阅多久（天）没更新就自动关闭；0 = 从不。
  final int autoDisableDays;

  /// null = 不显示「自动关闭」档位菜单。
  final ValueChanged<int>? onAutoDisableDaysChanged;

  /// 每个订阅最近一次发现新集的时刻；null = 停用卡不标「多久未更新」。
  final Future<Map<String, int>> Function()? latestDiscoveredLoader;

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
  Map<String, int>? _latestDiscovered;

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
    loader()
        .then((Map<String, Map<String, int>> counts) {
          if (mounted) setState(() => _itemCounts = counts);
        })
        .catchError((Object _) {
          // 计数是增强信息，查询失败不影响订阅列表本体。
        });
    widget.latestDiscoveredLoader
        ?.call()
        .then((Map<String, int> latest) {
          if (mounted) setState(() => _latestDiscovered = latest);
        })
        .catchError((Object _) {});
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

  /// 给 Apple 版式（part 里的 extension）用的 setState 入口。
  void _appleUpdate(VoidCallback fn) => setState(fn);

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

  static String autoDisablePeriodLabel(int days) => days >= 365
      ? t.subscription_auto_disable_one_year
      : t.subscription_auto_disable_half_year;

  static String _autoDisableChoiceLabel(int days) => days <= 0
      ? t.subscription_auto_disable_never
      : autoDisablePeriodLabel(days);

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
          if (widget.onAutoDisableDaysChanged != null) ...<Widget>[
            const SizedBox(width: 8),
            FushiOverflowMenu<int>(
              key: const ValueKey<String>('video-subscription-auto-disable'),
              tooltip: t.subscription_auto_disable_tooltip,
              onSelected: widget.onAutoDisableDaysChanged!,
              items: <PopupMenuEntry<int>>[
                for (final int days
                    in kVideoDownloadSubscriptionAutoDisableChoices)
                  FushiPopupMenuItem<int>(
                    value: days,
                    label: _autoDisableChoiceLabel(days),
                    selected: widget.autoDisableDays == days,
                  ),
              ],
              child: FushiOutlinedButton.icon(
                onPressed: null,
                style: kFushiMenuTriggerButtonStyle,
                icon: const FushiIcon(FushiIcons.schedule, size: 18),
                label: Text(
                  t.subscription_auto_disable_label(
                    period: _autoDisableChoiceLabel(widget.autoDisableDays),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 顶部汇总（紧凑工具条，一行 ~56 高）：订阅数 · 启用数 + 调度说明 +「全部检查」。
  Widget _buildHeader() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiTypography type = context.fushiType;
    final int enabled = widget.subscriptions
        .where((VideoDownloadSubscriptionRow row) => row.enabled)
        .length;
    final Color? onContainer = fushiCardToneColors(
      context,
      FushiCardTone.secondary,
    )?.onContainer;
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
        padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
        child: Row(
          children: <Widget>[
            const FushiListLeadingIcon(
              FushiIcons.notifications,
              shape: FushiLeadingShape.cookie,
              tone: FushiCardTone.primary,
              size: 36,
              iconSize: 18,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    t.download_subscription_summary(
                      n: widget.subscriptions.length,
                      enabled: enabled,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.titleSmallEmphasized.tabular.copyWith(
                      color: onContainer,
                    ),
                  ),
                  Text(
                    t.download_subscription_running_hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.labelSmall.copyWith(color: onContainer),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FushiFilledButton.tonalIcon(
              key: const ValueKey<String>('video-subscription-check-all'),
              onPressed: widget.checkingAll || enabled == 0
                  ? null
                  : widget.onCheckAll,
              icon: widget.checkingAll
                  ? const SizedBox.square(
                      dimension: 16,
                      child: FushiCircularProgressIndicator(strokeWidth: 2),
                    )
                  : const FushiIcon(FushiIcons.refresh, size: 18),
              label: Text(
                t.download_subscription_check_all,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
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
      autoDisableDays: widget.autoDisableDays,
      showStale: _latestDiscovered != null,
      latestDiscoveredAt: _latestDiscovered?[subscription.subscriptionId],
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

  /// 宽于此值时三列：紧凑卡只有 ~130 高，两列在超宽屏上每张拉到 700+ 宽，
  /// 一行里大半是空白；三列让同屏订阅数翻 1.5 倍、行长仍够放下 meta。
  static const double _kGridBreakpoint3 = 1600;

  @override
  Widget build(BuildContext context) {
    final List<VideoDownloadSubscriptionRow> visible =
        sortedVideoDownloadSubscriptions(
          filterVideoDownloadSubscriptions(widget.subscriptions, _searchQuery),
          _sort,
        );
    if (isGlassDesign(context)) return _buildApple(context, visible);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double page = tokens.spacing.page;
    final double gap = tokens.spacing.gap;
    // 叠放的浮动头部（浏览页一二级页签行）让出的高度：整页是一个滚动视图，
    // 顶部自己占位，汇总 / 搜索 / 卡片都滚到头部之下（BUG-2975）。
    final double chromeInset = FushiFloatingChromeInset.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final int columns = width >= _kGridBreakpoint3
            ? 3
            : width >= _kGridBreakpoint
            ? 2
            : 1;
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
          // 卡片 builder 恒返回非空，错峰进场包装后也恒非空。
          final NullableIndexedWidgetBuilder entrance =
              fushiStaggeredItemBuilder(
                (BuildContext context, int index) => _buildCard(visible[index]),
              );
          body = SliverPadding(
            padding: EdgeInsets.fromLTRB(page, gap, page, 24),
            // 两列时按瀑布流排：每张卡落进当前较短的一列，卡高不一（规则多、
            // 展开逐集状态）时不再按行顶对齐留出大块空白（2026-10-20 用户截图）。
            sliver: SliverMasonryGrid.count(
              crossAxisCount: columns,
              mainAxisSpacing: gap + 4,
              crossAxisSpacing: gap + 4,
              childCount: visible.length,
              itemBuilder: (BuildContext context, int index) =>
                  entrance(context, index)!,
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

/// 订阅卡上的一枚状态小签（已完成 / 久未更新）。
class _SubscriptionChip extends StatelessWidget {
  const _SubscriptionChip({required this.icon, required this.label, this.tone});

  final IconData icon;
  final String label;

  /// null = 中性 surfaceContainerHigh；给了就是该色调的饱和色块。
  final FushiCardTone? tone;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final FushiCardColors? toned = tone == null
        ? null
        : fushiCardToneColors(context, tone!);
    final Color background =
        toned?.container ??
        (glass ? appleColorsOf(context).fill : cs.surfaceContainerHigh);
    final Color foreground = toned?.onContainer ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: FushiM3eShape.smallRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(icon, size: 13, color: foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.labelSmall.tabular.copyWith(
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 订阅行 `lastError` 的用户文案：引擎的配置错误按稳定分类
/// （[VideoDownloadSubscriptionConfigIssue]）映射成本地化句子——原文是冻结的
/// 英文诊断串，不直接摆给用户；来源站失败等未分类的原文照旧显示（已脱敏，含
/// 来源名与原因，对排查有用）。
String videoDownloadSubscriptionErrorLabel(String lastError) {
  final String raw = lastError.trim();
  if (raw == kVideoSubscriptionCheckFailedError) {
    return t.download_subscription_error_check_failed;
  }
  return switch (VideoDownloadSubscriptionConfigIssue.fromLastError(raw)) {
    null => raw,
    VideoDownloadSubscriptionConfigIssue.invalidMode ||
    VideoDownloadSubscriptionConfigIssue.invalidMediaKind ||
    VideoDownloadSubscriptionConfigIssue.invalidSubtitlePolicy =>
      t.download_subscription_error_corrupted,
    VideoDownloadSubscriptionConfigIssue.targetSourceUnavailable =>
      t.download_subscription_error_target_source,
    VideoDownloadSubscriptionConfigIssue.backendBindingIncomplete =>
      t.download_subscription_error_backend,
    VideoDownloadSubscriptionConfigIssue.legacyOrganization =>
      t.subscription_legacy_hint,
    VideoDownloadSubscriptionConfigIssue.providerNotConfigured =>
      t.download_subscription_error_provider,
    VideoDownloadSubscriptionConfigIssue.invalidVersionFilter ||
    VideoDownloadSubscriptionConfigIssue.nonStrictVersionFilter =>
      t.download_subscription_error_filter,
    VideoDownloadSubscriptionConfigIssue.nyaaRulesIncomplete =>
      t.download_subscription_error_nyaa_rules,
    VideoDownloadSubscriptionConfigIssue.torznabRulesMissing =>
      t.download_subscription_error_torznab_rules,
    VideoDownloadSubscriptionConfigIssue.btSiteMissing =>
      t.bt_site_missing_status,
  };
}

/// 卡内一行状态（错误 / 暂停原因）：状态色图标 + 单行文字 + 可选动作；文字被
/// 截断时悬停 / 长按看全文（[detail] 给了就附上原始诊断串）。
class _SubscriptionStatusLine extends StatelessWidget {
  const _SubscriptionStatusLine({
    required this.tone,
    required this.icon,
    required this.message,
    this.detail,
    this.action,
    super.key,
  });

  final FushiStatusTone tone;
  final IconData icon;
  final String message;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final Color color = fushiStatusColor(context, tone);
    final String? raw = detail;
    final String tooltip = raw == null || raw == message
        ? message
        : '$message\n$raw';
    return Row(
      children: <Widget>[
        FushiIcon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: FushiTooltip(
            message: tooltip,
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.labelMedium.copyWith(color: color),
            ),
          ),
        ),
        ?action,
      ],
    );
  }
}

/// 订阅卡（拼贴改版紧凑形态，2026-11）：
/// - 首行：小海报 + 标题 /「类型 · 来源 · 模式」+ 开关；
/// - 一行调度 meta（下次 · 上次 · 最近命中，过去时刻用相对时间；起始集）；
/// - 一行规则签（停用原因签在前）；
/// - 一行状态（错误 / 暂停原因，带图标，截断时 tooltip 看全文）；
/// - 底行：失败红签 + 逐集计数 + 图标动作（逐集状态 / 编辑 / 检查 / 删除）。
class _VideoDownloadSubscriptionCard extends StatelessWidget {
  const _VideoDownloadSubscriptionCard({
    super.key,
    required this.subscription,
    required this.busy,
    required this.onToggle,
    required this.onCheck,
    required this.onDelete,
    this.onEdit,
    this.autoDisableDays = 0,
    this.latestDiscoveredAt,
    this.showStale = false,
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

  /// 追更订阅自动关闭的天数（0 = 从不），用来给停用卡标出原因。
  final int autoDisableDays;

  /// 最近一次发现新集的时刻；null = 一集都没发现过。
  final int? latestDiscoveredAt;

  /// 新集时刻已加载，可以判「多久未更新」。
  final bool showStale;

  /// status → count（[VideoDownloadSubscriptionItemStatus] 值域）。
  final Map<String, int> itemCounts;
  final bool expanded;
  final VideoDownloadSubscriptionItemsWatcher? itemsWatcher;
  final VoidCallback? onToggleExpanded;

  bool get _isLegacy => subscription.organizationPolicy == 'legacy';

  /// 过去的时刻（上次检查 / 最近命中）用相对时间：一眼看出「多久没动了」。
  static String _pastTime(int? milliseconds, DateTime now) {
    if (milliseconds == null) return t.download_subscription_never_checked;
    return formatActivityRelativeTime(milliseconds, now);
  }

  /// 将来的时刻（下次检查）：今天只给时分，跨天给日期 + 时分。
  static String _futureTime(int milliseconds, DateTime now) {
    final DateTime time = DateTime.fromMillisecondsSinceEpoch(
      milliseconds,
    ).toLocal();
    final bool sameDay =
        time.year == now.year && time.month == now.month && time.day == now.day;
    return sameDay
        ? FushiTimeFormat.hourMinute(time)
        : FushiTimeFormat.dateHourMinute(time);
  }

  /// 来源显示名：`nyaa:nyaa.si` 这类「格式:站点」只留站点（完整 id 进 tooltip）。
  static String _providerLabel(String provider) {
    final int colon = provider.indexOf(':');
    if (colon < 0 || colon == provider.length - 1) return provider;
    return provider.substring(colon + 1);
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

  /// 逐集计数摘要（`已入库 5 · 排队中 1 · 已跳过 2`）；零计数跳过，失败单独
  /// 走红签。
  String get _itemCountsLine {
    const List<String> order = <String>[
      VideoDownloadSubscriptionItemStatus.processed,
      VideoDownloadSubscriptionItemStatus.queued,
      VideoDownloadSubscriptionItemStatus.discovered,
      VideoDownloadSubscriptionItemStatus.skipped,
    ];
    final List<String> parts = <String>[
      for (final String status in order)
        if ((itemCounts[status] ?? 0) > 0)
          '${itemStatusLabel(status)} ${itemCounts[status]}',
    ];
    return parts.join('  ·  ');
  }

  Widget _buildCover(BuildContext context) {
    const double width = 40;
    const double height = 60;
    final String url = subscription.coverUrl?.trim() ?? '';
    final Widget placeholder = ColoredBox(
      color: FushiDesignTokens.of(context).surfaces.group,
      child: const Center(child: FushiIcon(FushiIcons.video, size: 20)),
    );
    final FushiMotionScheme motion = context.fushiMotion;
    // 停用的订阅封面降饱和（透明度走 effects 弹簧，不过冲）。
    return AnimatedOpacity(
      opacity: subscription.enabled ? 1 : 0.45,
      duration: motion.effectsDefault.duration,
      curve: motion.effectsDefault.curve,
      // 列表行小图：光面海报材质简化档（用户 2026-10-26），与放送日历同款。
      child: SizedBox(
        width: width,
        height: height,
        child: ShelfCoverMaterialScope(
          material: ShelfCoverMaterial.glossyPoster,
          child: ShelfCoverFrame(
            density: ShelfCoverDensity.compact,
            backgroundColor: FushiDesignTokens.of(context).surfaces.group,
            // 占位底色走设计令牌，且 errorBuilder 必须给 —— PortraitCoverImage
            // 加载失败会返回 SizedBox.shrink()，不给就是封面 404 / 断网留空洞。
            child: url.isEmpty
                ? placeholder
                : PortraitCoverImage(
                    image: AppCachedHttpImage(url),
                    errorBuilder: (_) => placeholder,
                  ),
          ),
        ),
      ),
    );
  }

  /// 调度 meta：图标 + 文字的内联串，最多两行。
  Widget _buildSchedule(BuildContext context, DateTime now, Color color) {
    final TextStyle style = context.fushiType.labelMedium.tabular.copyWith(
      color: color,
    );
    final int? next = subscription.nextCheckAt;
    final List<(IconData, String)> parts = <(IconData, String)>[
      if (subscription.enabled && next != null)
        (
          FushiIcons.schedule,
          t.subscription_next_check(time: _futureTime(next, now)),
        ),
      (
        FushiIcons.history,
        t.download_subscription_last_checked(
          time: _pastTime(subscription.lastCheckedAt, now),
        ),
      ),
      if (subscription.lastMatchedAt != null)
        (
          FushiIcons.downloadDone,
          t.subscription_last_matched(
            time: _pastTime(subscription.lastMatchedAt, now),
          ),
        ),
      if (subscription.startAfterEpisode case final int episode)
        (
          FushiIcons.skipNext,
          t.download_subscription_start_episode(episode: episode),
        ),
    ];
    return Text.rich(
      TextSpan(
        style: style,
        children: <InlineSpan>[
          for (int i = 0; i < parts.length; i++) ...<InlineSpan>[
            if (i > 0) const TextSpan(text: '  ·  '),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: 3),
                child: FushiIcon(parts[i].$1, size: 13, color: color),
              ),
            ),
            TextSpan(text: parts[i].$2),
          ],
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 状态行：legacy 说明 / BT 站缺失（带入口）/ 其它错误（本地化 + 原文 tooltip）。
  Widget? _buildStatus(BuildContext context) {
    if (_isLegacy) {
      return _SubscriptionStatusLine(
        tone: FushiStatusTone.warning,
        icon: FushiIcons.info,
        message: t.subscription_legacy_hint,
      );
    }
    final String lastError = subscription.lastError?.trim() ?? '';
    if (lastError.isEmpty) return null;
    if (isVideoSubscriptionBtSiteMissingError(lastError)) {
      // 没有可用 BT 站而暂停：不显示引擎的英文标记，给去添加的入口。用户加完
      // 站点后 setBtSites 会唤醒这些订阅。
      return _SubscriptionStatusLine(
        key: ValueKey<String>(
          'video-subscription-bt-site-missing-${subscription.subscriptionId}',
        ),
        tone: FushiStatusTone.warning,
        icon: FushiIcons.warning,
        message: t.bt_site_missing_status,
        action: FushiTextButton(
          key: ValueKey<String>(
            'video-subscription-bt-site-open-${subscription.subscriptionId}',
          ),
          onPressed: () => unawaited(pushBtSiteSettingsPage(context)),
          child: Text(t.bt_site_open_settings_action),
        ),
      );
    }
    return _SubscriptionStatusLine(
      key: ValueKey<String>(
        'video-subscription-error-${subscription.subscriptionId}',
      ),
      tone: FushiStatusTone.error,
      icon: FushiIcons.error,
      message: videoDownloadSubscriptionErrorLabel(lastError),
      detail: lastError,
    );
  }

  Widget _buildSourceLine(BuildContext context, Color secondary, Color accent) {
    final String modeLabel = subscription.mode == 'oneShot'
        ? t.subscription_mode_one_shot
        : t.subscription_mode_ongoing;
    final String mediaLabel = subscription.mediaKind == 'movie'
        ? t.collection_relation_movie
        : t.series;
    final Color modeColor = subscription.enabled ? accent : secondary;
    return FushiTooltip(
      message: subscription.resourceProvider,
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text:
                  '$mediaLabel  ·  '
                  '${_providerLabel(subscription.resourceProvider)}  ·  ',
            ),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: 3),
                child: FushiIcon(
                  subscription.mode == 'oneShot'
                      ? FushiIcons.download
                      : FushiIcons.repeat,
                  size: 13,
                  color: modeColor,
                ),
              ),
            ),
            TextSpan(
              text: modeLabel,
              style: TextStyle(color: modeColor, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.fushiType.labelMedium.copyWith(color: secondary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
    final DateTime now = DateTime.now();
    final bool glass = isGlassDesign(context);
    final Color secondary = glass
        ? appleColorsOf(context).secondaryLabel
        : cs.onSurfaceVariant;
    final Color accent = glass ? appleColorsOf(context).accent : cs.primary;
    final List<String> strictParts = videoDownloadSubscriptionFilterSummary(
      subscription.filterJson,
    );
    final String title = subscription.year == null
        ? subscription.title
        : '${subscription.title} (${subscription.year})';
    final String countsLine = _itemCountsLine;
    final int failed =
        itemCounts[VideoDownloadSubscriptionItemStatus.failed] ?? 0;
    // 停用原因：单次订阅下到即关；追更订阅超过设定时长没有更新（服务据此自动关闭）。
    final bool fulfilled =
        !subscription.enabled && subscription.fulfilledAt != null;
    final bool stale =
        !subscription.enabled &&
        showStale &&
        isVideoDownloadSubscriptionStale(
          subscription,
          nowAt: now.millisecondsSinceEpoch,
          days: autoDisableDays,
          latestDiscoveredAt: latestDiscoveredAt,
        );
    final Widget? status = _buildStatus(context);
    final Widget history = expanded && itemsWatcher != null
        ? _SubscriptionItemsSection(
            subscription: subscription,
            itemsWatcher: itemsWatcher!,
          )
        : const SizedBox(width: double.infinity);
    final String failedLabel = itemStatusLabel(
      VideoDownloadSubscriptionItemStatus.failed,
    );
    return FushiCard(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildCover(context),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.titleSmallEmphasized,
                    ),
                    const SizedBox(height: 2),
                    _buildSourceLine(context, secondary, accent),
                    const SizedBox(height: 4),
                    _buildSchedule(context, now, secondary),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              FushiSwitch.adaptive(
                key: ValueKey<String>(
                  'video-subscription-toggle-${subscription.subscriptionId}',
                ),
                value: subscription.enabled,
                onChanged: busy ? null : onToggle,
              ),
            ],
          ),
          if (strictParts.isNotEmpty ||
              _isLegacy ||
              fulfilled ||
              stale) ...<Widget>[
            const SizedBox(height: 8),
            Semantics(
              container: true,
              label: t.subscription_rules_title,
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (fulfilled)
                    _SubscriptionChip(
                      icon: FushiIcons.downloadDone,
                      label: t.subscription_fulfilled_chip,
                      tone: FushiCardTone.tertiary,
                    ),
                  if (stale)
                    _SubscriptionChip(
                      icon: FushiIcons.schedule,
                      label: t.subscription_stale_chip(
                        period:
                            _VideoDownloadSubscriptionsViewState.autoDisablePeriodLabel(
                              autoDisableDays,
                            ),
                      ),
                      tone: FushiCardTone.error,
                    ),
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
            ),
          ],
          if (status != null) ...<Widget>[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 4),
              child: status,
            ),
          ],
          Row(
            children: <Widget>[
              if (failed > 0) ...<Widget>[
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
                    '$failedLabel $failed',
                    style: type.labelSmallEmphasized.tabular.copyWith(
                      color: cs.onError,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  countsLine,
                  key: countsLine.isEmpty
                      ? null
                      : ValueKey<String>(
                          'video-subscription-items-${subscription.subscriptionId}',
                        ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.labelMedium.tabular.copyWith(color: secondary),
                ),
              ),
              if (onToggleExpanded != null)
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: motion.spatialFast.duration,
                  curve: motion.spatialFast.curve,
                  child: FushiIconButton(
                    key: ValueKey<String>(
                      'video-subscription-expand-${subscription.subscriptionId}',
                    ),
                    tooltip: t.subscription_show_items,
                    icon: FushiIcons.expandMore,
                    onTap: onToggleExpanded,
                  ),
                ),
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
          // 逐集历史：spatial 弹簧撑开 / 收起（墨水屏 / 减弱动态效果下瞬时，由
          // FushiAnimatedSize 处理零时长）。
          FushiAnimatedSize(
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 4),
              child: history,
            ),
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
      builder:
          (
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
                              Expanded(
                                child: FushiSkeleton.line(widthFactor: 0.6),
                              ),
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
    // 可信规则说人话：`trusted: true` / `trustedOnly: true` = 只要可信发布，
    // `trusted: false` = 只要非可信发布；`trustedOnly: false` 等于不限，不出签
    // （此前把原始布尔拼成「可信: false」直接显示）。语义与引擎匹配一致
    // （video_download_subscription_service 的候选过滤）。
    final Object? trusted = decoded['trusted'];
    final Object? trustedOnly = decoded['trustedOnly'];
    if (trusted == true || (trusted == null && trustedOnly == true)) {
      result.add(t.anime_download_trusted_only);
    } else if (trusted == false) {
      result.add(t.subscription_rule_untrusted_only);
    }
    return result.toSet().toList(growable: false);
  } on FormatException {
    return const <String>[];
  }
}
