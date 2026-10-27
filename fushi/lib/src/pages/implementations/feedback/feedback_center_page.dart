// 反馈中心：本机提交过的反馈与处理进度、「提交反馈」、开发者账户的处理台入口。
// 入口：首页顶栏按钮与悬浮球（openFeedbackCenter）。进页面即拉一次全部进度。
// 横屏宽屏时与处理台同形：左列表右详情（FeedbackSplitLayout）。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_fix_progress.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_compose_page.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_detail_page.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_dev_page.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';

class FeedbackCenterPage extends ConsumerStatefulWidget {
  const FeedbackCenterPage({this.initialScreenshot, super.key});

  /// 打开反馈中心前截下的画面（新反馈的默认截图，用户可删）。
  final Uint8List? initialScreenshot;

  @override
  ConsumerState<FeedbackCenterPage> createState() => _FeedbackCenterPageState();
}

class _FeedbackCenterPageState extends ConsumerState<FeedbackCenterPage> {
  String? _refreshError;

  /// 「我的反馈」本机搜索（编号 / 标题 / 正文）。
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'feedback-search');
  String _query = '';

  /// 状态筛选（反馈人视角：全部 / 进行中 / 已结案 / 有新回复）。
  FeedbackTicketFilter _filter = FeedbackTicketFilter.all;

  /// 宽屏分栏时右栏正在看的反馈 id（窄屏不用，窄屏点击直接 push 详情页）。
  String? _selectedId;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // 开发者入口看 /v1/me 的 role：已登录但本进程还没拉过自己时补拉一次（self 可能
    // 只是冷启动读的本机缓存，role 以服务端为准）。
    final LeaderboardService board = ref.read(leaderboardServiceProvider);
    if (board.status == LeaderboardStatus.active && !board.selfFresh) {
      unawaited(board.refreshSelf().then((_) {}, onError: (Object _) {}));
    }
  }

  Future<void> _refresh() async {
    try {
      await ref.read(feedbackServiceProvider).refresh();
      if (mounted) setState(() => _refreshError = null);
    } on Object catch (e) {
      if (mounted) setState(() => _refreshError = feedbackErrorReason(e));
    }
  }

  Future<void> _compose() async {
    final FeedbackSubmitResult? result = await Navigator.push(
      context,
      adaptivePageRoute<FeedbackSubmitResult>(
        context: context,
        builder: (_) =>
            FeedbackComposePage(initialScreenshot: widget.initialScreenshot),
      ),
    );
    if (result == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      FushiSnackBar(
        content: Text(
          result.failedAttachments > 0
              ? t.feedback_submitted_partial(n: result.failedAttachments)
              : t.feedback_submitted,
        ),
      ),
    );
  }

  void _openDetail(FeedbackTicket ticket, {required bool split}) {
    if (split) {
      setState(() => _selectedId = ticket.id);
      return;
    }
    unawaited(
      Navigator.push(
        context,
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => FeedbackDetailPage(feedbackId: ticket.id),
        ),
      ),
    );
  }

  void _openInbox() => unawaited(
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const FeedbackDevPage(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final FeedbackService service = ref.watch(feedbackServiceProvider);
    final List<FeedbackTicket> all = service.tickets;
    // 右栏那条已从本机移除（或刷新后不在清单里）就退回占位。
    final String? selectedId =
        all.any((FeedbackTicket x) => x.id == _selectedId) ? _selectedId : null;
    return FushiPageScaffold(
      title: t.feedback_title,
      actions: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('feedback-center-refresh'),
          icon: FushiIcons.refresh,
          tooltip: t.refresh,
          enabled: !service.refreshing,
          onTap: () => unawaited(_refresh()),
        ),
      ],
      body: FeedbackSplitLayout(
        keyPrefix: 'feedback-center',
        selectedId: selectedId,
        emptyMessage: t.feedback_dev_select_hint,
        detailBuilder: (String id) => FeedbackDetailPage(
          key: ValueKey<String>('feedback-center-pane-$id'),
          feedbackId: id,
          embedded: true,
          onRemoved: () => setState(() => _selectedId = null),
        ),
        listBuilder: (BuildContext context, bool split, double hPadding) =>
            _list(context, service, split: split, hPadding: hPadding),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    FeedbackService service, {
    required bool split,
    required double hPadding,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final LeaderboardSelf? self = ref.watch(
      leaderboardServiceProvider.select((LeaderboardService s) => s.self),
    );
    final List<FeedbackTicket> all = service.tickets;
    final List<FeedbackTicket> tickets = <FeedbackTicket>[
      for (final FeedbackTicket x in filterFeedbackTickets(all, _query))
        if (feedbackTicketMatchesFilter(x, _filter)) x,
    ];
    return FushiRefreshIndicator(
      edgeOffset: MediaQuery.paddingOf(context).top,
      onRefresh: _refresh,
      child: FushiEntranceScope(
        replayKey: _filter,
        enabled: service.loaded,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: withBottomSafeInset(
            context,
            EdgeInsets.fromLTRB(
              hPadding,
              tokens.spacing.card + MediaQuery.paddingOf(context).top,
              hPadding,
              tokens.spacing.card,
            ),
          ),
          children: <Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: FushiPressScale(
                child: FushiFilledButton.icon(
                  key: const ValueKey<String>('feedback-center-new'),
                  onPressed: () => unawaited(_compose()),
                  icon: const FushiIcon(FushiIcons.add),
                  label: Text(t.feedback_new),
                ),
              ),
            ),
            if (self?.isDeveloper ?? false) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              FushiCard(
                key: const ValueKey<String>('feedback-center-inbox'),
                onTap: _openInbox,
                padding: EdgeInsets.symmetric(
                  horizontal: tokens.spacing.gap,
                  vertical: tokens.spacing.gap / 2,
                ),
                child: FushiListItem(
                  density: FushiListDensity.compact,
                  leading: const FushiIcon(FushiIcons.code),
                  title: Text(t.feedback_dev_title),
                  subtitle: Text(t.feedback_dev_entry_hint),
                  trailing: const FushiIcon(FushiIcons.chevronRight),
                ),
              ),
            ],
            if (_refreshError != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                t.feedback_refresh_failed,
                style: tokens.type.listSubtitle.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            SizedBox(height: tokens.spacing.gap),
            if (service.loaded && all.isNotEmpty) ...<Widget>[
              FushiSearchField(
                fieldKey: const ValueKey<String>('feedback-center-search'),
                controller: _search,
                focusNode: _searchFocus,
                hintText: t.feedback_search_hint,
                onChanged: (String v) => setState(() => _query = v),
                onSubmitted: (String v) => setState(() => _query = v),
                onClear: () => setState(() => _query = ''),
              ),
              SizedBox(height: tokens.spacing.gap),
              Wrap(
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: <Widget>[
                  for (final FeedbackTicketFilter f
                      in FeedbackTicketFilter.values)
                    FushiChoiceChip(
                      key: ValueKey<String>('feedback-center-filter-${f.name}'),
                      label: Text(feedbackTicketFilterLabel(f)),
                      selected: _filter == f,
                      onSelected: (bool _) => setState(() => _filter = f),
                    ),
                ],
              ),
              SizedBox(height: tokens.spacing.gap),
            ],
            if (!service.loaded)
              const FushiLoadingView()
            else if (all.isEmpty)
              FushiPlaceholderMessage(
                icon: FushiIcons.forum,
                message: t.feedback_center_empty,
              )
            else if (tickets.isEmpty)
              FushiPlaceholderMessage(
                icon: FushiIcons.searchOff,
                message: t.feedback_search_empty,
              )
            else
              for (int i = 0; i < tickets.length; i++)
                FushiStaggeredEntrance(
                  index: i,
                  child: _TicketTile(
                    ticket: tickets[i],
                    selected: split && _selectedId == tickets[i].id,
                    reopenedAs: <String>[
                      for (final FeedbackTicket x in all)
                        if (x.parentId == tickets[i].id) x.id,
                    ],
                    onTap: () => _openDetail(tickets[i], split: split),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _TicketTile extends ConsumerWidget {
  const _TicketTile({
    required this.ticket,
    required this.reopenedAs,
    required this.onTap,
    this.selected = false,
  });

  final FeedbackTicket ticket;

  /// 本机清单里由这条重新提交出来的新反馈。
  final List<String> reopenedAs;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    // 只有带修复的条目才需要本机通道 / 版本（没修复的不碰 AppModel）。
    final FeedbackFix? fix = ticket.missing ? null : ticket.fix;
    final String? fixLabel = fix == null
        ? null
        : feedbackFixLabel(
            ref.watch(feedbackFixEnvironmentProvider).progress(fix),
          );
    return FeedbackListTile(
      key: ValueKey<String>('feedback-ticket-${ticket.id}'),
      id: ticket.id,
      category: ticket.category,
      title: ticket.title,
      meta: ticket.missing
          ? t.feedback_detail_missing
          : '${feedbackCategoryLabel(ticket.category)} · '
                '${feedbackTime(ticket.updatedAt)}',
      status: ticket.status,
      selected: selected,
      onTap: onTap,
      details: <Widget>[
        if (ticket.viaAccount)
          Text(
            t.feedback_from_other_device,
            key: ValueKey<String>('feedback-ticket-account-${ticket.id}'),
            style: tokens.type.metadata,
          ),
        if (fixLabel != null)
          Text(
            fixLabel,
            key: ValueKey<String>('feedback-ticket-fix-${ticket.id}'),
            style: tokens.type.metadata.copyWith(color: colors.tertiary),
          ),
        if (ticket.parentId != null)
          Text(
            t.feedback_reopen_of(id: ticket.parentId!),
            key: ValueKey<String>('feedback-ticket-parent-${ticket.id}'),
            style: tokens.type.metadata.copyWith(color: colors.primary),
          ),
        for (final String id in reopenedAs)
          Text(
            t.feedback_reopened_as(id: id),
            style: tokens.type.metadata.copyWith(color: colors.primary),
          ),
      ],
      badges: <Widget>[
        if (ticket.hasUnseenReply)
          FushiTooltip(
            message: t.feedback_new_reply,
            child: Semantics(
              label: t.feedback_new_reply,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.error,
                  shape: BoxShape.circle,
                ),
                child: const SizedBox.square(dimension: 8),
              ),
            ),
          ),
      ],
    );
  }
}
