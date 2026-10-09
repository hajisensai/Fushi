// 反馈中心：本机提交过的反馈与处理进度、「提交反馈」、开发者账户的处理台入口。
// 入口：首页顶栏按钮与悬浮球（openFeedbackCenter）。进页面即拉一次全部进度。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // 开发者入口看 /v1/me 的 role：已登录但还没拉过自己时补拉一次。
    final LeaderboardService board = ref.read(leaderboardServiceProvider);
    if (board.status == LeaderboardStatus.active && board.self == null) {
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

  void _openDetail(FeedbackTicket ticket) => unawaited(
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => FeedbackDetailPage(feedbackId: ticket.id),
      ),
    ),
  );

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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FeedbackService service = ref.watch(feedbackServiceProvider);
    final LeaderboardSelf? self = ref.watch(
      leaderboardServiceProvider.select((LeaderboardService s) => s.self),
    );
    final List<FeedbackTicket> tickets = service.tickets;
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
      body: Builder(
        builder: (BuildContext context) => FushiRefreshIndicator(
          edgeOffset: MediaQuery.paddingOf(context).top,
          onRefresh: _refresh,
          child: FushiEntranceScope(
            enabled: service.loaded,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: withBottomSafeInset(
                context,
                EdgeInsets.fromLTRB(
                  tokens.spacing.card,
                  tokens.spacing.card + MediaQuery.paddingOf(context).top,
                  tokens.spacing.card,
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
                  SizedBox(height: tokens.spacing.card),
                  FushiCard(
                    key: const ValueKey<String>('feedback-center-inbox'),
                    onTap: _openInbox,
                    child: FushiListItem(
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
                SizedBox(height: tokens.spacing.card),
                if (!service.loaded)
                  const FushiLoadingView()
                else if (tickets.isEmpty)
                  FushiPlaceholderMessage(
                    icon: FushiIcons.forum,
                    message: t.feedback_center_empty,
                  )
                else
                  for (int i = 0; i < tickets.length; i++)
                    FushiStaggeredEntrance(
                      index: i,
                      child: _TicketTile(
                        ticket: tickets[i],
                        onTap: () => _openDetail(tickets[i]),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TicketTile extends StatelessWidget {
  const _TicketTile({required this.ticket, required this.onTap});

  final FeedbackTicket ticket;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: FushiCard(
        key: ValueKey<String>('feedback-ticket-${ticket.id}'),
        onTap: onTap,
        child: FushiListItem(
          leading: FushiIcon(feedbackCategoryIcon(ticket.category)),
          title: Text(ticket.title),
          subtitle: Text(
            ticket.missing
                ? t.feedback_detail_missing
                : '${feedbackCategoryLabel(ticket.category)} · '
                      '${feedbackTime(ticket.updatedAt)}',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (ticket.hasUnseenReply)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FushiTooltip(
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
                ),
              FeedbackStatusBadge(ticket.status),
            ],
          ),
        ),
      ),
    );
  }
}
