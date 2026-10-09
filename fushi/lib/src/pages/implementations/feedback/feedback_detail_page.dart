// 反馈人看自己的一条反馈：正文、状态、开发者回复与状态变更时间线、追加说明。
// 服务端查不到（ticket 失效 / 被清理）时给「从本机移除」。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';

class FeedbackDetailPage extends ConsumerStatefulWidget {
  const FeedbackDetailPage({required this.feedbackId, super.key});

  final String feedbackId;

  @override
  ConsumerState<FeedbackDetailPage> createState() => _FeedbackDetailPageState();
}

class _FeedbackDetailPageState extends ConsumerState<FeedbackDetailPage> {
  final TextEditingController _reply = TextEditingController();
  FeedbackDetail? _detail;
  String? _error;
  bool _missing = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final FeedbackDetail d = await ref
          .read(feedbackServiceProvider)
          .detail(widget.feedbackId);
      if (mounted) {
        setState(() {
          _detail = d;
          _error = null;
        });
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _missing = e is LeaderboardApiException && e.status == 404;
        _error = feedbackErrorReason(e);
      });
    }
  }

  Future<void> _send() async {
    final String text = _reply.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      final FeedbackDetail d = await ref
          .read(feedbackServiceProvider)
          .reply(widget.feedbackId, text);
      if (!mounted) return;
      _reply.clear();
      setState(() => _detail = d);
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        FushiSnackBar(
          content: Text(
            t.feedback_submit_failed(reason: feedbackErrorReason(e)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _forget() async {
    await ref.read(feedbackServiceProvider).forget(widget.feedbackId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FeedbackTicket? local = ref.watch(
      feedbackServiceProvider.select(
        (FeedbackService s) => s.byId(widget.feedbackId),
      ),
    );
    final FeedbackDetail? d = _detail;
    return FushiPageScaffold(
      title: d?.summary.title ?? local?.title ?? t.feedback_title,
      actions: <Widget>[
        FushiIconButton(
          icon: FushiIcons.delete,
          tooltip: t.feedback_detail_forget,
          onTap: () => unawaited(_forget()),
        ),
      ],
      body: Builder(
        builder: (BuildContext context) => FushiRefreshIndicator(
          edgeOffset: MediaQuery.paddingOf(context).top,
          onRefresh: _load,
          child: FushiEntranceScope(
            enabled: d != null,
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
                if (d == null && _missing)
                  FushiPlaceholderMessage(
                    icon: FushiIcons.searchOff,
                    message: t.feedback_detail_missing,
                    action: FushiTextButton(
                      onPressed: () => unawaited(_forget()),
                      child: Text(t.feedback_detail_forget),
                    ),
                  )
                else if (d == null && _error != null)
                  FushiPlaceholderMessage(
                    icon: FushiIcons.cloudOff,
                    tone: FushiPlaceholderTone.error,
                    message: t.feedback_refresh_failed,
                    detail: _error,
                    action: FushiTextButton(
                      onPressed: () => unawaited(_load()),
                      child: Text(t.refresh),
                    ),
                  )
                else if (d == null)
                  const FushiLoadingView()
                else ...<Widget>[
                  FushiStaggeredEntrance(
                    index: 0,
                    child: FushiCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              FeedbackStatusBadge(d.status),
                              SizedBox(width: tokens.spacing.gap),
                              Expanded(
                                child: Text(
                                  '${feedbackCategoryLabel(d.summary.category)} · '
                                  '#${d.id} · ${feedbackTime(d.summary.createdAt)}',
                                  style: tokens.type.metadata,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: tokens.spacing.gap),
                          SelectableText(d.body),
                          if (d.attachments.isNotEmpty) ...<Widget>[
                            SizedBox(height: tokens.spacing.gap),
                            Text(
                              t.feedback_detail_attachments(
                                n: d.attachments.length,
                              ),
                              style: tokens.type.metadata,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: tokens.spacing.card),
                  FushiSectionTitle(t.feedback_detail_timeline),
                  FeedbackTimeline(messages: d.messages),
                  SizedBox(height: tokens.spacing.card),
                  FushiTextField(
                    key: const ValueKey<String>('feedback-reply'),
                    controller: _reply,
                    enabled: !_sending,
                    hintText: t.feedback_detail_reply_hint,
                    keyboardType: TextInputType.multiline,
                    minLines: 2,
                    maxLines: 6,
                    maxLength: FeedbackLimits.replyMax,
                  ),
                  SizedBox(height: tokens.spacing.gap),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FushiPressScale(
                      enabled: !_sending,
                      child: FushiFilledButton.icon(
                        key: const ValueKey<String>('feedback-reply-send'),
                        onPressed: _sending ? null : () => unawaited(_send()),
                        icon: const FushiIcon(FushiIcons.forward),
                        label: Text(t.feedback_detail_reply_send),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
