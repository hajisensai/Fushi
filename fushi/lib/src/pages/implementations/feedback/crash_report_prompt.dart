// 闪退报告的界面：启动时「Fushi 上次意外退出了 · 发送给开发者 / 以后自动发送 / 不用了」。
// 状态与流程在 `feedback/crash_report.dart`（[CrashReporter]）。
//
// 两个出口：
// - 首页出来之后（[offerCrashReportAfterStartup]）：app 级浮层卡片（[CrashReportPromptHost]，
//   挂在 MaterialApp builder 里、导航之上），15 秒不点自动收起。没点任何按钮 = 下次
//   启动再问（攒下的几次合在一起）；「不用了」= 这批作废。
//   不用 SnackBar：提示要活过根 MaterialApp 的整树重挂（界面语言 key 一变就重挂），
//   而 SnackBar 绑在当时的 ScaffoldMessengerState 上——旧 messenger 被 dispose 后，经
//   GlobalKey 搬进新树的首页 Scaffold 还画着旧提示条，点「不用了 / 发送」都在已 dispose
//   的动画控制器上抛空指针：关不掉、也发不出去（反馈 msySECp2Cy）；它还画在首页 Scaffold
//   里，会被推上来的页面盖住（反馈 jmgMk1gHG2）。
// - 启动即闪退（[runCrashReportStartupGate]）：上次死在初始化完成之前，这次的初始化多半
//   还会死、首页根本出不来，所以提示放在加载页上、**等用户选完再初始化**（开着自动发送
//   时不问，提交在后台跑、不拖住初始化）；那时数据库还没开，提交落在
//   [CrashReporter.spoolDir]，首页出来后并入反馈中心。

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart';
import 'package:fushi/src/feedback/crash_report.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart'
    show kLeaderboardDefaultBaseUrl;
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart'
    show openFeedbackTicket;
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiCard;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiFilledButton, FushiTextButton;
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiSnackBar;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:material_ui/material_ui.dart';

/// 首页出来后的提示条停留多久（不点就收起，下次启动再问）。
const Duration kCrashReportPromptDuration = Duration(seconds: 15);

/// 退出种类的界面文案。
String crashKindLabel(PreviousExitKind kind) => switch (kind) {
  PreviousExitKind.nativeCrash => t.feedback_crash_kind_native,
  PreviousExitKind.crash => t.feedback_crash_kind_crash,
  PreviousExitKind.anr => t.feedback_crash_kind_anr,
  PreviousExitKind.memoryKill => t.feedback_crash_kind_memory,
  PreviousExitKind.unexpected ||
  PreviousExitKind.userStopped ||
  PreviousExitKind.appUpdated ||
  PreviousExitKind.backgroundReclaim => t.feedback_crash_kind_unexpected,
};

/// 种类 + 「启动时」限定。
String crashOfferKindLabel(CrashReportOffer offer) => offer.duringStartup
    ? '${crashKindLabel(offer.kind)} · ${t.feedback_crash_kind_startup}'
    : crashKindLabel(offer.kind);

/// 按当前界面语言组一份闪退报告反馈。
FeedbackDraft crashReportDraftFor(
  CrashReportOffer offer,
  String submissionKey,
) {
  final String kind = crashOfferKindLabel(offer);
  final String counted = offer.totalCount > 1
      ? '$kind x${offer.totalCount}'
      : kind;
  return buildCrashReportDraft(
    offer,
    title: t.feedback_crash_report_title(kind: counted, version: offer.version),
    header: t.feedback_crash_report_header,
    submissionKey: submissionKey,
  );
}

// ───────────────────────── 提示卡片 ─────────────────────────

/// 提示卡片：标题（种类 / 次数）+ 说明 + 三个按钮；发送中 / 失败时原地切换（带动效）。
///
/// [onSend] 的参数 = 用户点的是「以后自动发送」；它抛出时卡片显示失败并给「重试 /
/// 跳过」（[onSkip] 为 null 时不给跳过）。
class CrashReportPromptCard extends StatefulWidget {
  const CrashReportPromptCard({
    required this.offer,
    required this.onSend,
    required this.onDecline,
    this.onSkip,
    this.foreground,
    super.key,
  });

  final CrashReportOffer offer;
  final Future<void> Function(bool alwaysSend) onSend;
  final VoidCallback onDecline;
  final VoidCallback? onSkip;

  /// 文字与按钮颜色（SnackBar 里要用反色）；null = 跟主题。
  final Color? foreground;

  @override
  State<CrashReportPromptCard> createState() => _CrashReportPromptCardState();
}

enum _PromptPhase { idle, sending, failed }

class _CrashReportPromptCardState extends State<CrashReportPromptCard> {
  _PromptPhase _phase = _PromptPhase.idle;
  bool _lastAlways = false;

  Future<void> _send(bool always) async {
    setState(() {
      _phase = _PromptPhase.sending;
      _lastAlways = always;
    });
    try {
      await widget.onSend(always);
    } on Object catch (e, st) {
      ErrorLogService.instance.log('CrashReport.prompt_send', e, st);
      if (mounted) setState(() => _phase = _PromptPhase.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color? fg = widget.foreground;
    final CrashReportOffer offer = widget.offer;
    final String kind = crashOfferKindLabel(offer);
    final String title = offer.totalCount > 1
        ? t.feedback_crash_prompt_title_many(n: offer.totalCount, kind: kind)
        : t.feedback_crash_prompt_title(kind: kind);
    final ButtonStyle buttonStyle = TextButton.styleFrom(
      foregroundColor: fg,
      minimumSize: const Size(48, 48),
    );
    final Duration motion = fushiMotionDuration(context, FushiMotion.short);

    final Widget actions = switch (_phase) {
      _PromptPhase.idle => Wrap(
        key: const ValueKey<String>('crash-report-idle'),
        alignment: WrapAlignment.end,
        spacing: 4,
        children: <Widget>[
          FushiTextButton(
            key: const ValueKey<String>('crash-report-decline'),
            style: buttonStyle,
            onPressed: widget.onDecline,
            child: Text(t.feedback_crash_prompt_decline),
          ),
          FushiTextButton(
            key: const ValueKey<String>('crash-report-always'),
            style: buttonStyle,
            onPressed: () => unawaited(_send(true)),
            child: Text(t.feedback_crash_prompt_always),
          ),
          FushiFilledButton.tonal(
            key: const ValueKey<String>('crash-report-send'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => unawaited(_send(false)),
            child: Text(t.feedback_crash_prompt_send),
          ),
        ],
      ),
      _PromptPhase.sending => Row(
        key: const ValueKey<String>('crash-report-sending'),
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          const SizedBox.square(
            dimension: 18,
            child: FushiCircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(
            t.feedback_crash_prompt_sending,
            style: theme.textTheme.bodyMedium?.copyWith(color: fg),
          ),
        ],
      ),
      _PromptPhase.failed => Column(
        key: const ValueKey<String>('crash-report-failed'),
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Text(
            t.feedback_crash_send_failed,
            style: theme.textTheme.bodySmall?.copyWith(
              color: fg ?? theme.colorScheme.error,
            ),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: <Widget>[
              if (widget.onSkip != null)
                FushiTextButton(
                  key: const ValueKey<String>('crash-report-skip'),
                  style: buttonStyle,
                  onPressed: widget.onSkip,
                  child: Text(t.feedback_crash_prompt_skip),
                ),
              FushiFilledButton.tonal(
                key: const ValueKey<String>('crash-report-retry'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => unawaited(_send(_lastAlways)),
                child: Text(t.feedback_crash_prompt_retry),
              ),
            ],
          ),
        ],
      ),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FushiIcon(FushiIcons.error, color: fg, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(color: fg),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.feedback_crash_prompt_body,
                    style: theme.textTheme.bodySmall?.copyWith(color: fg),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FushiAnimatedSize(
          duration: motion,
          curve: context.fushiMotion.spatialFast.curve,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(duration: motion, child: actions),
        ),
      ],
    );
  }
}

// ───────────────────────── 首页出来之后 ─────────────────────────

/// 首页出来后的提示（null = 没有）。[CrashReportPromptHost] 监听它显示 / 收起卡片；状态
/// 不挂在任何 widget 上，根 MaterialApp 重挂也不丢、不失效。
final ValueNotifier<CrashReportPromptRequest?> crashReportHomePrompt =
    ValueNotifier<CrashReportPromptRequest?>(null);

/// 一次首页出来后的提示：卡片按钮的回调。
class CrashReportPromptRequest {
  CrashReportPromptRequest({
    required this.offer,
    required this.onSend,
    required this.onDecline,
  });

  final CrashReportOffer offer;
  final Future<void> Function(bool alwaysSend) onSend;
  final VoidCallback onDecline;
}

/// 收起 [request]（已经换成别的提示时不动）。
void _closeHomePrompt(CrashReportPromptRequest request) {
  if (identical(crashReportHomePrompt.value, request)) {
    crashReportHomePrompt.value = null;
  }
}

/// 首页出来后调一次：先并入启动前提交的回执；本次启动还没处理过、有该问的报告时，
/// 开着自动发送就直接发（发完给一条可点「查看」的提示），否则显示浮层提示卡片。
Future<void> offerCrashReportAfterStartup({
  required BuildContext Function() context,
  required CrashReporter reporter,
  required FeedbackService service,
}) async {
  await reporter.adoptSpool(service);
  if (reporter.handledThisSession) return;
  final CrashReportOffer? offer = reporter.currentOffer();
  if (offer == null) return;
  reporter.markHandledThisSession();
  if (reporter.autoSend) {
    try {
      await reporter.submit(service, crashReportDraftFor);
      _showSentNotice(context(), reporter, auto: true);
    } on Object catch (e, st) {
      // 待报与幂等键都留着：下次启动再自动发，拿回的是同一条反馈。
      ErrorLogService.instance.log('CrashReport.auto_send', e, st);
    }
    return;
  }
  late final CrashReportPromptRequest request;
  request = CrashReportPromptRequest(
    offer: offer,
    onDecline: () {
      reporter.decline();
      _closeHomePrompt(request);
    },
    onSend: (bool always) async {
      if (always) reporter.setAutoSend(true);
      // 卡片马上收起（它 15 秒后反正会收），提交在后台跑完再报结果。
      _closeHomePrompt(request);
      unawaited(_submitInBackground(context, reporter, service));
    },
  );
  crashReportHomePrompt.value = request;
}

/// 首页出来后的提示卡片宿主：挂在 MaterialApp builder 的导航之上（盖住所有页面），
/// 没有提示时不占位。卡片显示满 [duration] 没点就收起（这批留着，下次启动再问）。
class CrashReportPromptHost extends StatelessWidget {
  const CrashReportPromptHost({
    this.duration = kCrashReportPromptDuration,
    super.key,
  });

  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CrashReportPromptRequest?>(
      valueListenable: crashReportHomePrompt,
      builder:
          (
            BuildContext context,
            CrashReportPromptRequest? request,
            Widget? child,
          ) {
            if (request == null) return const SizedBox.shrink();
            return _CrashReportHomePrompt(
              // 换了一次提示就重新入场、重新计时。
              key: ObjectKey(request),
              request: request,
              duration: duration,
            );
          },
    );
  }
}

class _CrashReportHomePrompt extends StatefulWidget {
  const _CrashReportHomePrompt({
    required this.request,
    required this.duration,
    super.key,
  });

  final CrashReportPromptRequest request;
  final Duration duration;

  @override
  State<_CrashReportHomePrompt> createState() => _CrashReportHomePromptState();
}

class _CrashReportHomePromptState extends State<_CrashReportHomePrompt> {
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    _timeout = Timer(widget.duration, () => _closeHomePrompt(widget.request));
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  void _cancelTimeout() {
    _timeout?.cancel();
    _timeout = null;
  }

  @override
  Widget build(BuildContext context) {
    return _CrashReportFloatingCard(
      cardKey: const ValueKey<String>('crash-report-prompt'),
      offer: widget.request.offer,
      onSend: (bool always) {
        _cancelTimeout();
        return widget.request.onSend(always);
      },
      onDecline: () {
        _cancelTimeout();
        widget.request.onDecline();
      },
    );
  }
}

/// 底部浮动卡片（滑入 + 淡入）：启动前提示与首页出来后的提示共用。
class _CrashReportFloatingCard extends StatefulWidget {
  const _CrashReportFloatingCard({
    required this.cardKey,
    required this.offer,
    required this.onSend,
    required this.onDecline,
    this.onSkip,
  });

  final Key cardKey;
  final CrashReportOffer offer;
  final Future<void> Function(bool alwaysSend) onSend;
  final VoidCallback onDecline;
  final VoidCallback? onSkip;

  @override
  State<_CrashReportFloatingCard> createState() =>
      _CrashReportFloatingCardState();
}

class _CrashReportFloatingCardState extends State<_CrashReportFloatingCard> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final Duration motion = fushiMotionDuration(context, FushiMotion.medium);
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedSlide(
          offset: _shown ? Offset.zero : const Offset(0, 0.3),
          duration: motion,
          curve: context.fushiMotion.spatialDefault.curve,
          child: AnimatedOpacity(
            opacity: _shown ? 1 : 0,
            duration: motion,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: FushiCard(
                key: widget.cardKey,
                margin: const EdgeInsets.all(16),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 12, 8),
                  child: CrashReportPromptCard(
                    offer: widget.offer,
                    onSend: widget.onSend,
                    onDecline: widget.onDecline,
                    onSkip: widget.onSkip,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _submitInBackground(
  BuildContext Function() context,
  CrashReporter reporter,
  FeedbackService service,
) async {
  try {
    await reporter.submit(service, crashReportDraftFor);
    _showSentNotice(context(), reporter, auto: false);
  } on Object catch (e, st) {
    ErrorLogService.instance.log('CrashReport.send', e, st);
    final BuildContext ctx = context();
    if (!ctx.mounted) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
      FushiSnackBar(
        key: const ValueKey<String>('crash-report-failed'),
        persist: false,
        content: Text(t.feedback_crash_send_failed),
      ),
    );
  }
}

void _showSentNotice(
  BuildContext context,
  CrashReporter reporter, {
  required bool auto,
}) {
  if (!context.mounted) return;
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final String? id = reporter.lastTicketId;
  if (messenger == null) return;
  messenger.showSnackBar(
    FushiSnackBar(
      key: const ValueKey<String>('crash-report-sent'),
      persist: false,
      content: Text(
        auto ? t.feedback_crash_auto_sent_notice : t.feedback_crash_sent_notice,
      ),
      action: id == null
          ? null
          : SnackBarAction(
              label: t.feedback_crash_notice_view,
              onPressed: () => unawaited(openFeedbackTicket(context, id)),
            ),
    ),
  );
}

// ───────────────────────── 启动即闪退 ─────────────────────────

/// 加载页上要显示的启动前提示（null = 没有）。根 widget 监听它：非空时释放首帧、
/// 停掉加载看门狗、在加载页底部显示 [CrashReportStartupPrompt]。
final ValueNotifier<CrashReportStartupRequest?> crashReportStartupPrompt =
    ValueNotifier<CrashReportStartupRequest?>(null);

/// 一次启动前提示：卡片的回调经它把结果交回 [runCrashReportStartupGate]。
class CrashReportStartupRequest {
  CrashReportStartupRequest(this.offer, this._send);

  final CrashReportOffer offer;
  final Future<void> Function(bool alwaysSend) _send;
  final Completer<void> _done = Completer<void>();

  Future<void> send(bool alwaysSend) async {
    await _send(alwaysSend);
    finish();
  }

  void finish() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// 启动前提交用的反馈服务：数据根还没解析，落在 [CrashReporter.spoolDir]；匿名、连默认
/// 服务地址（自定义排行榜服务器的设置在数据库里，这时读不到）。
FeedbackService crashReportSpoolService(CrashReporter reporter) =>
    FeedbackService(
      supportRoot: () async => reporter.spoolDir!,
      client: () => LeaderboardClient(
        baseUrl: Uri.parse(kLeaderboardDefaultBaseUrl),
        httpClientFactory: () async => createAppHttpIoClient(),
      ),
    );

/// `AppModel.initialise()` 之前调：上次死在初始化完成之前、有该问的报告时，开着自动
/// 发送就在后台开始提交、**立刻返回**（只做本机的事：这批连幂等键落盘，网络在后台跟
/// 初始化并行跑，弱网下不拖住初始化、不触发加载看门狗）；否则在加载页显示提示、等用户
/// 选完（发送成功 / 不用了 / 失败后跳过）再返回。其余情况立刻返回，交给首页出来后的
/// [offerCrashReportAfterStartup]。
///
/// 等用户选的这段时间在会话标记里记着（[PreviousExitLog.markAwaitingCrashReportDecision]）：
/// 用户停在提示上直接把 app 关掉 / 杀掉，下次启动按用户结束处理，不再算一次启动即闪退。
///
/// [spoolService] / [markAwaitingDecision] 只给测试替换。
Future<void> runCrashReportStartupGate(
  CrashReporter reporter, {
  FeedbackService? spoolService,
  void Function(bool awaiting) markAwaitingDecision =
      PreviousExitLog.markAwaitingCrashReportDecision,
}) async {
  final CrashReportOffer? offer = reporter.currentOffer();
  if (offer == null || !offer.duringStartup || reporter.spoolDir == null) {
    return;
  }
  reporter.markHandledThisSession();
  final FeedbackService service =
      spoolService ?? crashReportSpoolService(reporter);
  if (reporter.autoSend) {
    reporter.submitInBackground(service, crashReportDraftFor);
    return;
  }
  final CrashReportStartupRequest request = CrashReportStartupRequest(offer, (
    bool always,
  ) async {
    if (always) reporter.setAutoSend(true);
    await reporter.submit(service, crashReportDraftFor);
  });
  markAwaitingDecision(true);
  crashReportStartupPrompt.value = request;
  try {
    await request._done.future;
  } finally {
    crashReportStartupPrompt.value = null;
    markAwaitingDecision(false);
  }
}

/// 加载页上的启动前提示（底部卡片，滑入 + 淡入）。
class CrashReportStartupPrompt extends StatefulWidget {
  const CrashReportStartupPrompt({
    required this.request,
    required this.reporter,
    super.key,
  });

  final CrashReportStartupRequest request;
  final CrashReporter reporter;

  @override
  State<CrashReportStartupPrompt> createState() =>
      _CrashReportStartupPromptState();
}

class _CrashReportStartupPromptState extends State<CrashReportStartupPrompt> {
  @override
  Widget build(BuildContext context) {
    return _CrashReportFloatingCard(
      cardKey: const ValueKey<String>('crash-report-startup-prompt'),
      offer: widget.request.offer,
      onSend: widget.request.send,
      onDecline: () {
        widget.reporter.decline();
        widget.request.finish();
      },
      onSkip: widget.request.finish,
    );
  }
}
