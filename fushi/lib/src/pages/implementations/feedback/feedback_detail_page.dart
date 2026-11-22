// 反馈人看自己的一条反馈：正文、状态、开发者回复与状态变更时间线、追加说明。
// 服务端查不到（ticket 失效 / 被清理）时给「从本机移除」。附件：截图凭本机 ticket 取回
// 显示缩略图、点开看大图；日志与视频只列条目（服务端不把它们回传给反馈人）。
// 本机有没传上去的附件时给「重试上传」；补传窗口内（提交后 24 小时、本机回执）可「追加视频」。
// 账户列表里的条目（别的设备提交的）凭账户签名查看，没有「从本机移除」与补传。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/feedback/feedback_video.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_compose_page.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi/src/utils/misc/gallery_image_picker.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';

class FeedbackDetailPage extends ConsumerStatefulWidget {
  const FeedbackDetailPage({
    required this.feedbackId,
    this.embedded = false,
    this.onRemoved,
    super.key,
  });

  final String feedbackId;

  /// 嵌在反馈中心宽屏分栏的右栏里：没有「返回」（右栏不是一条路由）。
  final bool embedded;

  /// 嵌入时「从本机移除」后通知宿主收起右栏（独立页面是 pop）。
  final VoidCallback? onRemoved;

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
    HardwareKeyboard.instance.addHandler(_onKey);
    unawaited(_load());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _reply.dispose();
    super.dispose();
  }

  /// 桌面 Ctrl+V（macOS Cmd+V）：与提交页同一快捷键（[isFeedbackPasteShortcut]），
  /// 还能追加截图时看一眼剪贴板，有图就追加。不吃掉按键——回复框照常粘贴文字。
  bool _onKey(KeyEvent event) {
    if (!isFeedbackPasteShortcut(event)) return false;
    // 只认最上层：详情页上面又压了别的页面 / 弹窗时不抢。
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    final FeedbackDetail? d = _detail;
    if (d == null || _addingShot || _shotRoom(d) <= 0) return false;
    unawaited(_pasteShot(d, explicit: false));
    return false;
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

  bool _retrying = false;
  bool _addingShot = false;
  bool _addingVideo = false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(message)));
  }

  /// 汇报一次补传的结果，并在有附件传上去时刷新详情（缩略图才会出现）。
  Future<void> _reportRetry(FeedbackRetryResult r) async {
    if (r.quotaResetAt != null) {
      _snack(
        t.feedback_pending_quota(
          n: r.remaining,
          time: feedbackQuotaResetTime(r.quotaResetAt!),
        ),
      );
    } else if (r.remaining > 0) {
      _snack(t.feedback_pending_retry_failed(n: r.remaining));
    } else if (r.dropped > 0) {
      _snack(t.feedback_pending_dropped(n: r.dropped));
    } else if (r.uploaded > 0) {
      _snack(t.feedback_pending_retry_done(n: r.uploaded));
    }
    if (r.uploaded > 0) await _load();
  }

  /// 手动重试上次没传上去的附件（截图 / 日志 / 视频）。
  Future<void> _retryPending() async {
    setState(() => _retrying = true);
    try {
      await _reportRetry(
        await ref.read(feedbackServiceProvider).retryPending(widget.feedbackId),
      );
    } on Object catch (e) {
      _snack(t.feedback_submit_failed(reason: feedbackErrorReason(e)));
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  /// 已占的截图名额：服务端已有的截图 + 本机待传的截图槽位。视频（v0）、样本文件
  /// （f0..f2）与日志不占截图名额。
  int _shotsUsed(FeedbackDetail d, FeedbackService service) =>
      d.attachments.where((FeedbackAttachmentInfo a) => a.isScreenshot).length +
      service
          .pendingSlots(widget.feedbackId)
          .where(
            (String s) =>
                s != 'log' &&
                s != FeedbackLimits.videoSlot &&
                !FeedbackLimits.isFileSlot(s),
          )
          .length;

  /// 还能追加几张截图；补传窗口过了（或本机没有这条反馈的回执）为 0。
  int _shotRoom(FeedbackDetail d) {
    final FeedbackService service = ref.read(feedbackServiceProvider);
    final FeedbackTicket? local = service.byId(widget.feedbackId);
    if (local == null || !service.canAttach(local)) return 0;
    return FeedbackLimits.screenshots - _shotsUsed(d, service);
  }

  /// 追加截图的共用一段：[source] 按剩余名额取图（相册 / 剪贴板），取到就上传。
  /// [source] 返回空表 = 用户取消或没有图，什么也不传。
  Future<void> _appendShots(
    FeedbackDetail d,
    Future<List<Uint8List>> Function(int room) source,
  ) async {
    if (_addingShot) return;
    final FeedbackService service = ref.read(feedbackServiceProvider);
    final int room = _shotRoom(d);
    if (room <= 0) return;
    setState(() => _addingShot = true);
    try {
      final List<Uint8List> shots = await source(room);
      if (shots.isEmpty || !mounted) return;
      final FeedbackRetryResult r = await service.addScreenshots(
        widget.feedbackId,
        shots.take(room).toList(growable: false),
        usedSlots: <String>{
          for (final FeedbackAttachmentInfo a in d.attachments) a.slot,
        },
      );
      await _reportRetry(r);
    } on Object catch (e) {
      _snack(t.feedback_submit_failed(reason: feedbackErrorReason(e)));
    } finally {
      if (mounted) setState(() => _addingShot = false);
    }
  }

  /// 给这条反馈追加一张截图（相册选图）。
  Future<void> _addShot(FeedbackDetail d) => _appendShots(d, (int _) async {
    final File? file = await pickGalleryImageFile();
    if (file == null) return const <Uint8List>[];
    return <Uint8List>[await prepareFeedbackImage(await file.readAsBytes())];
  });

  /// 把剪贴板里的图片追加进这条反馈（与提交页同一个取图入口
  /// [readFeedbackImagesFromClipboard]）。[explicit]（按钮）时没图 / 读失败给一句
  /// 提示；Ctrl+V 粘的多半是回复文字，没图时不打扰。
  Future<void> _pasteShot(FeedbackDetail d, {required bool explicit}) =>
      _appendShots(d, (int room) async {
        final List<Uint8List> images;
        try {
          images = await readFeedbackImagesFromClipboard(limit: room);
        } on Object catch (e, st) {
          ErrorLogService.instance.log('feedback.paste_image', e, st);
          if (explicit) _snack(t.feedback_compose_paste_failed);
          return const <Uint8List>[];
        }
        if (images.isEmpty && explicit) {
          _snack(t.feedback_compose_paste_none);
        }
        return images;
      });

  /// 追加视频：选文件 → 本机转码 → 上传（进度见 [FeedbackService.videoTransfer]）。
  Future<void> _addVideo() async {
    final FeedbackService service = ref.read(feedbackServiceProvider);
    setState(() => _addingVideo = true);
    try {
      final File? picked = await pickFeedbackVideoFile();
      if (picked == null) return;
      final FeedbackRetryResult r = await service.addVideo(
        widget.feedbackId,
        picked,
      );
      if (r.remaining == 0 && r.dropped == 0 && r.uploaded > 0) {
        _snack(t.feedback_detail_video_added);
        await _load();
      } else {
        await _reportRetry(r);
      }
    } on Object catch (e) {
      _snack(
        feedbackVideoErrorText(e) ??
            t.feedback_submit_failed(reason: feedbackErrorReason(e)),
      );
    } finally {
      if (mounted) setState(() => _addingVideo = false);
    }
  }

  /// 待补传提示 / 视频进度 / 追加截图与追加视频入口。补传窗口（提交后 24 小时）过了、
  /// 截图槽位满了、或已经有视频时，不给对应的追加入口；本机还留着没传上去的附件时，窗口
  /// 过了照样显示提示（重试会被丢弃并说明）。
  List<Widget> _attachActions(FeedbackDetail d, FushiDesignTokens tokens) {
    final FeedbackService service = ref.watch(feedbackServiceProvider);
    final FeedbackTicket? local = service.byId(widget.feedbackId);
    final Set<String> pending = service.pendingSlots(widget.feedbackId);
    final FeedbackVideoTransfer? transfer = service.videoTransfer(
      widget.feedbackId,
    );
    final bool attachable = local != null && service.canAttach(local);
    // 待传槽位在上传进行中时也在 [pending] 里（追加截图先落盘再传）：这时它们是「正在传」，
    // 不是「没传上去」，不能显示失败提示与重试按钮（#aiRZmYl5zS）。
    final bool uploading = service.attachInFlight(widget.feedbackId);
    // 今天的上传额度用完：提醒几点后重试，而不是笼统的「没上传成功」。
    final DateTime? quotaResetAt = service.uploadQuotaResetAt(
      widget.feedbackId,
    );
    final bool canAddShot =
        attachable && _shotsUsed(d, service) < FeedbackLimits.screenshots;
    final bool hasVideo =
        d.attachments.any((FeedbackAttachmentInfo a) => a.isVideo) ||
        pending.contains(FeedbackLimits.videoSlot);
    final bool canAddVideo = attachable && !hasVideo && transfer == null;
    final double? fraction = transfer?.fraction;
    final String percent = fraction == null
        ? ''
        : '${(fraction * 100).floor()}%';
    return <Widget>[
      if (transfer != null) ...<Widget>[
        SizedBox(height: tokens.spacing.card),
        FushiCard(
          key: const ValueKey<String>('feedback-detail-video-progress'),
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                transfer.stage == FeedbackVideoStage.preparing
                    ? t.feedback_stage_video_prepare(percent: percent)
                    : t.feedback_stage_video(percent: percent),
              ),
              SizedBox(height: tokens.spacing.gap),
              FushiLinearProgressIndicator(value: fraction),
            ],
          ),
        ),
      ],
      if (uploading && transfer == null) ...<Widget>[
        SizedBox(height: tokens.spacing.card),
        FushiCard(
          key: const ValueKey<String>('feedback-detail-uploading'),
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                pending.isNotEmpty && pending.every((String s) => s == 'log')
                    ? t.feedback_stage_logs
                    : pending.isNotEmpty &&
                          pending.every(FeedbackLimits.isFileSlot)
                    ? t.feedback_stage_files
                    : t.feedback_stage_screenshots,
              ),
              SizedBox(height: tokens.spacing.gap),
              const FushiLinearProgressIndicator(),
            ],
          ),
        ),
      ],
      if (pending.isNotEmpty && !uploading && transfer == null) ...<Widget>[
        SizedBox(height: tokens.spacing.card),
        FushiInlineNotice(
          key: const ValueKey<String>('feedback-detail-pending'),
          severity: quotaResetAt == null
              ? FushiNoticeSeverity.info
              : FushiNoticeSeverity.warning,
          message: quotaResetAt == null
              ? t.feedback_pending_attachments(n: pending.length)
              : t.feedback_pending_quota(
                  n: pending.length,
                  time: feedbackQuotaResetTime(quotaResetAt),
                ),
          actions: <Widget>[
            FushiTextButton(
              key: const ValueKey<String>('feedback-detail-retry'),
              onPressed: _retrying ? null : () => unawaited(_retryPending()),
              child: Text(t.feedback_pending_retry),
            ),
          ],
        ),
      ],
      if (canAddShot || canAddVideo) ...<Widget>[
        SizedBox(height: tokens.spacing.gap),
        Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            if (canAddShot)
              FushiPressScale(
                enabled: !_addingShot,
                child: FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('feedback-detail-add-shot'),
                  onPressed: _addingShot ? null : () => unawaited(_addShot(d)),
                  icon: const FushiIcon(FushiIcons.addCircle),
                  label: Text(t.feedback_detail_add_shot),
                ),
              ),
            // 与提交页「粘贴图片」同一入口：剪贴板里的截图 / 复制的图片文件（BUG-5172）。
            if (canAddShot)
              FushiPressScale(
                enabled: !_addingShot,
                child: FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('feedback-detail-paste-shot'),
                  onPressed: _addingShot
                      ? null
                      : () => unawaited(_pasteShot(d, explicit: true)),
                  icon: const FushiIcon(FushiIcons.paste),
                  label: Text(t.feedback_compose_paste_image),
                ),
              ),
            if (canAddVideo)
              FushiPressScale(
                enabled: !_addingVideo,
                child: FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('feedback-detail-add-video'),
                  onPressed: _addingVideo ? null : () => unawaited(_addVideo()),
                  icon: const FushiIcon(FushiIcons.video),
                  label: Text(t.feedback_detail_video_add),
                ),
              ),
          ],
        ),
      ],
    ];
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
        if (a.isScreenshot) a,
    ];
    final FeedbackAttachmentInfo? video = d.attachments
        .where((FeedbackAttachmentInfo a) => a.isVideo)
        .firstOrNull;
    final FeedbackAttachmentInfo? log = d.attachments
        .where((FeedbackAttachmentInfo a) => a.isLog)
        .firstOrNull;
    final List<FeedbackAttachmentInfo> files = <FeedbackAttachmentInfo>[
      for (final FeedbackAttachmentInfo a in d.attachments)
        if (a.isFile) a,
    ];
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
        if (video != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          Row(
            key: const ValueKey<String>('feedback-detail-video'),
            children: <Widget>[
              const FushiIcon(FushiIcons.video),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t.feedback_detail_video(
                        size: FushiByteFormat.bytes(video.bytes),
                      ),
                    ),
                    Text(
                      t.feedback_detail_video_hint,
                      style: tokens.type.metadata,
                    ),
                  ],
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
        if (files.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          // 样本文件只列名字与大小：文件本身只有开发者能下载（服务端不回传给反馈人）。
          Row(
            key: const ValueKey<String>('feedback-detail-files'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const FushiIcon(FushiIcons.file),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(t.feedback_detail_files),
                    for (final FeedbackAttachmentInfo a in files)
                      Text(
                        '${feedbackSafeText(a.name ?? a.slot)} · '
                        '${FushiByteFormat.bytes(a.bytes)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.type.metadata,
                      ),
                    Text(
                      t.feedback_detail_files_hint,
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
    if (!mounted) return;
    if (widget.embedded) {
      widget.onRemoved?.call();
    } else {
      Navigator.of(context).pop();
    }
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
    // 账户列表里的条目删不掉（下次刷新又会列出来），不给「从本机移除」。
    final bool viaAccount = local?.viaAccount ?? false;
    return FushiPageScaffold(
      automaticallyImplyLeading: !widget.embedded,
      title: d?.summary.title ?? local?.title ?? t.feedback_title,
      actions: <Widget>[
        if (!viaAccount)
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
                    action: viaAccount
                        ? null
                        : FushiTextButton(
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
                          if (d.fix case final FeedbackFix fix) ...<Widget>[
                            SizedBox(height: tokens.spacing.gap),
                            FeedbackFixNotice(
                              fix,
                              key: const ValueKey<String>(
                                'feedback-fix-progress',
                              ),
                            ),
                          ],
                          if (d.body.isNotEmpty) ...<Widget>[
                            SizedBox(height: tokens.spacing.gap),
                            SelectableText(d.body),
                          ],
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
                  ..._attachActions(d, tokens),
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
