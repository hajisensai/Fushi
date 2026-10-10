// 反馈人看自己的一条反馈：正文、状态、开发者回复与状态变更时间线、追加说明。
// 服务端查不到（ticket 失效 / 被清理）时给「从本机移除」。附件：截图凭本机 ticket 取回
// 显示缩略图、点开看大图；日志只列条目（服务端不把日志回传给 ticket 持有者）。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_compose_page.dart';
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

  /// 截图字节按槽位缓存：刷新详情不重复下载（服务端对单条反馈的下载有限次）。
  /// 只缓存成功的下载：失败的槽位从缓存里摘掉、记进 [_failedShots]，点一下缩略图重取
  /// （否则一次网络抖动就让这张图在本次打开期间永远是坏图，BUG-3239）。
  final Map<String, Future<Uint8List>> _images = <String, Future<Uint8List>>{};
  final Set<String> _failedShots = <String>{};

  Future<Uint8List> _image(String slot) => _images[slot] ??= _download(slot);

  Future<Uint8List> _download(String slot) async {
    try {
      final Uint8List bytes = await ref
          .read(feedbackServiceProvider)
          .screenshot(widget.feedbackId, slot);
      _failedShots.remove(slot);
      return bytes;
    } on Object {
      _images.remove(slot);
      _failedShots.add(slot);
      rethrow;
    }
  }

  /// 点缩略图：上次取失败了就重取（重建出新的 Future），否则看大图。
  void _onShotTap(String slot) {
    if (_failedShots.contains(slot)) {
      setState(() => _failedShots.remove(slot));
      return;
    }
    _viewImage(slot);
  }

  void _viewImage(String slot) => unawaited(
    showAppDialog<void>(
      context: context,
      builder: (BuildContext ctx) => FushiDialog(
        child: InteractiveViewer(
          child: FutureBuilder<Uint8List>(
            future: _image(slot),
            builder: (BuildContext _, AsyncSnapshot<Uint8List> snap) =>
                snap.hasData
                ? Image.memory(snap.data!, cacheWidth: 2400)
                : snap.hasError
                ? const Center(child: FushiIcon(FushiIcons.brokenImage))
                : const FushiLoadingView(),
          ),
        ),
      ),
    ),
  );

  Widget _attachments(FeedbackDetail d, FushiDesignTokens tokens) {
    final List<FeedbackAttachmentInfo> shots = <FeedbackAttachmentInfo>[
      for (final FeedbackAttachmentInfo a in d.attachments)
        if (!a.isLog) a,
    ];
    final FeedbackAttachmentInfo? log = d.attachments
        .where((FeedbackAttachmentInfo a) => a.isLog)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (shots.isNotEmpty) ...<Widget>[
          FushiSectionTitle(t.feedback_dev_screenshots),
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              for (final FeedbackAttachmentInfo a in shots)
                FushiPressScale(
                  child: GestureDetector(
                    key: ValueKey<String>('feedback-detail-shot-${a.slot}'),
                    onTap: () => _onShotTap(a.slot),
                    child: ClipRRect(
                      borderRadius: FushiM3eShape.smallRadius,
                      child: SizedBox(
                        width: 96,
                        height: 128,
                        child: FutureBuilder<Uint8List>(
                          future: _image(a.slot),
                          builder:
                              (BuildContext _, AsyncSnapshot<Uint8List> snap) =>
                                  snap.hasData
                                  ? Image.memory(
                                      snap.data!,
                                      fit: BoxFit.cover,
                                      cacheWidth: 360,
                                    )
                                  : snap.hasError
                                  ? const Center(
                                      child: FushiIcon(FushiIcons.brokenImage),
                                    )
                                  : const FushiLoadingView(compact: true),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
        if (log != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          Row(
            key: const ValueKey<String>('feedback-detail-log'),
            children: <Widget>[
              const FushiIcon(FushiIcons.file),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t.feedback_detail_log(
                        size: FushiByteFormat.bytes(log.bytes),
                      ),
                    ),
                    Text(
                      t.feedback_detail_log_hint,
                      style: tokens.type.metadata,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  bool _closing = false;

  /// 关联的另一条本机有没有 ticket（别的设备提交的没有，看不了）。
  bool _canOpenRelated(String id) =>
      ref.read(feedbackServiceProvider).byId(id) != null;

  /// 打开关联的另一条（只对 [_canOpenRelated] 的条目可点）。
  void _openRelated(String id) {
    if (!_canOpenRelated(id)) return;
    unawaited(
      Navigator.push(
        context,
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => FeedbackDetailPage(feedbackId: id),
        ),
      ),
    );
  }

  /// 「问题没解决，重新提交」：打开预填了原反馈的提交页；交上去后回到这里并刷新关联。
  Future<void> _reopen(FeedbackDetail d) async {
    final FeedbackSubmitResult? result = await Navigator.push(
      context,
      adaptivePageRoute<FeedbackSubmitResult>(
        context: context,
        builder: (_) =>
            FeedbackComposePage(reopenOf: FeedbackReopenSeed.fromDetail(d)),
      ),
    );
    if (result == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(t.feedback_reopen_submitted)));
    await _load();
  }

  /// 反馈人只能把「待处理 / 处理中」标为完成（与服务端 REPORTER_CLOSABLE 一致）。
  static bool _closable(FeedbackStatus s) =>
      s == FeedbackStatus.open || s == FeedbackStatus.inProgress;

  Future<void> _markDone() async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.feedback_mark_done_confirm_title,
      message: t.feedback_mark_done_confirm_body,
      confirmLabel: t.feedback_mark_done,
      icon: FushiIcons.check,
    );
    if (!ok || !mounted) return;
    setState(() => _closing = true);
    try {
      final FeedbackDetail d = await ref
          .read(feedbackServiceProvider)
          .markDone(widget.feedbackId);
      if (!mounted) return;
      setState(() => _detail = d);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(FushiSnackBar(content: Text(t.feedback_marked_done)));
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
      if (mounted) setState(() => _closing = false);
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
                              Expanded(child: FeedbackMetaLine(d)),
                            ],
                          ),
                          if (d.summary.parentId != null ||
                              d.reopenedAs.isNotEmpty) ...<Widget>[
                            SizedBox(height: tokens.spacing.gap),
                            FeedbackRelationLinks(
                              parentId: d.summary.parentId,
                              reopenedAs: d.reopenedAs,
                              onOpen: _openRelated,
                              canOpen: _canOpenRelated,
                            ),
                          ],
                          SizedBox(height: tokens.spacing.gap),
                          SelectableText(d.body),
                          if (d.status.isClosed) ...<Widget>[
                            SizedBox(height: tokens.spacing.gap),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FushiPressScale(
                                child: FushiFilledButton.tonalIcon(
                                  key: const ValueKey<String>(
                                    'feedback-reopen',
                                  ),
                                  onPressed: () => unawaited(_reopen(d)),
                                  icon: const FushiIcon(FushiIcons.refresh),
                                  label: Text(t.feedback_reopen),
                                ),
                              ),
                            ),
                          ],
                          if (_closable(d.status)) ...<Widget>[
                            SizedBox(height: tokens.spacing.gap),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FushiPressScale(
                                enabled: !_closing,
                                child: FushiFilledButton.tonalIcon(
                                  key: const ValueKey<String>(
                                    'feedback-mark-done',
                                  ),
                                  onPressed: _closing
                                      ? null
                                      : () => unawaited(_markDone()),
                                  icon: const FushiIcon(FushiIcons.check),
                                  label: Text(t.feedback_mark_done),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (d.attachments.isNotEmpty) ...<Widget>[
                    SizedBox(height: tokens.spacing.card),
                    FushiStaggeredEntrance(
                      index: 1,
                      child: _attachments(d, tokens),
                    ),
                  ],
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
