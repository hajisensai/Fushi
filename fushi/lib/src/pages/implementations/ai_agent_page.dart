/// 「AI 助手」对话界面（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §5、§6.2、§6.4）：整页、手机半屏浮层、桌面靠边侧栏三种外壳共用
/// [AiAgentConversation]，渲染同一个 [AiAgentController] 的会话——从浮层展开成
/// 整页不丢对话。
///
/// 条目按 [AgentEntry] 渲染：写操作带「改前 → 改后」与「撤销」；不可逆 / 装扩展
/// 的确认卡片只能在这里点（模型代答不了）；候选卡片交给用户点选。
library;

import 'dart:async';
import 'dart:convert';

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:intl/intl.dart' show Intl, NumberFormat;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/ai/agent/ai_agent_conversation_controller.dart';
import 'package:fushi/src/ai/agent/remote_ai_agent_session.dart';
import 'package:fushi/src/sync/interconnect_assistant_client.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/assistant/video_acquisition_assistant_host.dart'
    show
        kHostAssistantReasonDisabled,
        kHostAssistantReasonNoProvider,
        kHostAssistantReasonNotReady;
import 'package:fushi/src/ai/agent/ai_agent_in_process_ops.dart';
import 'package:fushi/src/ocr/screen_text_capture.dart'
    show screenTextCaptureSupported;
import 'package:fushi/src/ops/app_op_context.dart';
import 'package:fushi/src/pages/implementations/ai_provider_settings_section.dart'
    show aiFailureText;
import 'package:fushi/src/pages/implementations/ai_agent_screen_text.dart';
import 'package:fushi/src/pages/implementations/ai_settings_route.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show fushiFloatingPillDecoration;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:url_launcher/url_launcher.dart';

/// 侧栏 / 浮层判宽阈值：宽于它的窗口用靠边侧栏，窄的用底部半屏面板。
const double kAiAgentSidePanelBreakpoint = 840;

/// 浮层 / 侧栏里对话区可用高度低于它（横屏手机弹出软键盘时只剩 130~175dp）就进
/// 「紧凑」排版：藏掉标题栏和上下文 chip，只留对话列表 + 输入栏。否则标题栏 + chip
/// 把高度吃光，输入框被裁掉，用户既输入不了也滚不动。
const double kAiAgentTightHeight = 200;

/// 装扩展类操作（D9）：确认卡片换成「要安装这个扩展吗？」的标题。
final RegExp _kExtensionInstallOp = RegExp(
  r'^online\.(extension\.(install|update)\w*|repo\.add)$',
);

/// 打开 AI 助手（悬浮球「AI」、首页卡片、快捷键共用这一个入口）。
///
/// 没指派提供商时不开会话、不发请求：提示并引导去「设置 › 模型 › LLM」
/// （BUG-2694 的约定）。窄屏弹底部半屏面板，宽屏从右侧滑出侧栏。
Future<void> openAiAgent(
  BuildContext context, {
  AgentUiContext? uiContext,
}) async {
  final AiAgentConversationController? controller =
      await _resolveAiAgentConversation(context);
  if (controller == null || !context.mounted) return;
  if (MediaQuery.sizeOf(context).width >= kAiAgentSidePanelBreakpoint) {
    await _showSidePanel(context, controller, uiContext);
    return;
  }
  await adaptiveModalSheet<void>(
    context: context,
    expandable: true,
    builder: (BuildContext sheetContext) => SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height * 0.55,
      child: AiAgentConversation(
        controller: controller,
        uiContext: uiContext,
        compact: true,
        onExpand: () {
          Navigator.of(sheetContext).pop();
          unawaited(pushAiAgentPage(context, uiContext: uiContext));
        },
      ),
    ),
  );
}

/// 整页（浮层右上角「展开成整页」也走这里）。
Future<void> pushAiAgentPage(
  BuildContext context, {
  AgentUiContext? uiContext,
}) async {
  final AiAgentConversationController? controller =
      await _resolveAiAgentConversation(context);
  if (controller == null || !context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext _) =>
          AiAgentPage(controller: controller, uiContext: uiContext),
    ),
  );
}

/// 本机还是远端（spec §6.5）——**只在这里决定**，[openAiAgent] / [pushAiAgentPage]
/// 共用：
///
/// - 本机给「AI 助手」指派了提供商 → 本机会话；
/// - 否则「下载执行设备」（与 AI 下视频远端同一个设置）指向一台已配对设备、且它
///   宣告了 `agent` → 整场会话交给它跑（复用正在用的那场，浮层 / 整页不丢对话）；
/// - 那台设备连不上 / 开不了 → 如实报原因，**不**退回本机；
/// - 都没有 → 保持现状：引导去「设置 › 模型 › LLM」，不发任何请求。
Future<AiAgentConversationController?> _resolveAiAgentConversation(
  BuildContext context,
) async {
  final AiAgentController? local = AiAgentController.instanceOrNull;
  if (local == null) return null;
  if (local.hasProvider) return local;
  final opContext = appOpContext;
  final String url =
      opContext?.appModel.prefsRepo.downloadExecutionHostUrl ?? '';
  if (opContext == null || url.isEmpty) {
    await _guideToProviderSettings(context);
    return null;
  }
  final SyncRepository repo = SyncRepository(opContext.appModel.database);
  // 解绑 / 停用了那台设备：偏好停在死地址上，按「没设执行设备」处理（与下载
  // 入口 resolveDownloadExecution 同一判据）。
  final FushiClientUrl? paired = interconnectPeerRepresentativeOf(
    await repo.getFushiClientUrls(),
    url,
  );
  if (!context.mounted) return null;
  if (paired == null) {
    await _guideToProviderSettings(context);
    return null;
  }
  final RemoteAiAgentSession? existing = RemoteAiAgentSession.active;
  if (existing != null && existing.isUsable && existing.target.baseUrl == url) {
    return existing;
  }
  existing?.dispose();
  final String deviceLabel = paired.deviceName ?? url;
  final InterconnectAssistantClient client = InterconnectAssistantClient(
    repo: repo,
  );
  final HostAssistantTarget? target = await client.probeUrl(url);
  if (!context.mounted) return null;
  if (target == null) {
    _showAiAgentMessage(
      context,
      t.ai_agent_remote_unreachable(device: deviceLabel),
    );
    return null;
  }
  if (!target.supports(kHostAssistantFeatureAgent)) {
    _showAiAgentMessage(
      context,
      _remoteBlockedText(
        target.label,
        target.reasonFor(kHostAssistantFeatureAgent),
      ),
    );
    return null;
  }
  try {
    final RemoteAiAgentSession session = await RemoteAiAgentSession.open(
      client: client,
      target: target,
      locale: opContext.appModel.appLocale.toLanguageTag(),
    );
    if (!context.mounted) {
      session.dispose();
      return null;
    }
    RemoteAiAgentSession.active = session;
    return session;
  } on HostAssistantException catch (error) {
    if (context.mounted) {
      _showAiAgentMessage(
        context,
        error.code == 'http_409'
            ? _remoteBlockedText(
                target.label,
                error.detail ?? kHostAssistantReasonNotReady,
              )
            : t.ai_agent_remote_unreachable(device: target.label),
      );
    }
    return null;
  } on Object {
    if (context.mounted) {
      _showAiAgentMessage(
        context,
        t.ai_agent_remote_unreachable(device: target.label),
      );
    }
    return null;
  }
}

String _remoteBlockedText(String device, String reason) => switch (reason) {
  kHostAssistantReasonNoProvider => t.ai_agent_remote_no_provider(
    device: device,
  ),
  kHostAssistantReasonNotReady => t.ai_agent_remote_not_ready(device: device),
  kHostAssistantReasonDisabled => t.ai_agent_remote_disabled(device: device),
  _ => t.ai_agent_remote_unsupported(device: device),
};

void _showAiAgentMessage(BuildContext context, String message) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    FushiToast.show(msg: message);
    return;
  }
  messenger.showSnackBar(
    FushiSnackBar(content: Text(message), duration: const Duration(seconds: 6)),
  );
}

Future<void> _guideToProviderSettings(BuildContext context) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    FushiToast.show(msg: t.ai_agent_no_provider);
    return;
  }
  messenger.showSnackBar(
    FushiSnackBar(
      content: Text(t.ai_agent_no_provider),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: t.ai_agent_open_settings,
        onPressed: () {
          final opContext = appOpContext;
          if (opContext != null) {
            unawaited(
              openAiAgentSettingsRow(opContext, kAiAgentProviderSettingsItem),
            );
          } else {
            unawaited(pushAiSettingsPage(context));
          }
        },
      ),
    ),
  );
}

Future<void> _showSidePanel(
  BuildContext context,
  AiAgentConversationController controller,
  AgentUiContext? uiContext,
) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.12),
    transitionDuration: fushiMotionDuration(context, FushiMotion.medium),
    pageBuilder:
        (
          BuildContext dialogContext,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          final ColorScheme scheme = Theme.of(dialogContext).colorScheme;
          // 软键盘把面板整块抬到键盘上方（对话框路由不会自己让位）。
          final double keyboard = MediaQuery.viewInsetsOf(dialogContext).bottom;
          return Align(
            alignment: AlignmentDirectional.centerEnd,
            child: AnimatedPadding(
              duration: fushiMotionDuration(dialogContext, FushiMotion.short),
              curve: FushiMotion.standard,
              padding: EdgeInsets.all(12) + EdgeInsets.only(bottom: keyboard),
              child: Material(
                color: scheme.surfaceContainerLow,
                elevation: 6,
                borderRadius: FushiBorderRadius.dialog,
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: 440,
                  height: double.infinity,
                  child: AiAgentConversation(
                    controller: controller,
                    uiContext: uiContext,
                    compact: true,
                    onExpand: () {
                      Navigator.of(dialogContext).pop();
                      unawaited(pushAiAgentPage(context, uiContext: uiContext));
                    },
                  ),
                ),
              ),
            ),
          );
        },
    transitionBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          final Animation<double> curved = CurvedAnimation(
            parent: animation,
            curve: FushiMotion.enter,
            reverseCurve: FushiMotion.exit,
          );
          final bool rtl = Directionality.of(context) == TextDirection.rtl;
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset(rtl ? -0.12 : 0.12, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
  );
}

/// 整页外壳。
class AiAgentPage extends StatelessWidget {
  const AiAgentPage({required this.controller, this.uiContext, super.key});

  final AiAgentConversationController controller;
  final AgentUiContext? uiContext;

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.ai_agent_title,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Builder(
          builder: (BuildContext bodyContext) => Padding(
            padding: EdgeInsets.only(
              top: MediaQuery.paddingOf(bodyContext).top,
            ),
            child: AiAgentConversation(
              controller: controller,
              uiContext: uiContext,
            ),
          ),
        ),
      ),
    );
  }
}

/// 对话本体：顶栏（紧凑外壳才有）+ 条目列表 + 输入栏。
class AiAgentConversation extends StatefulWidget {
  const AiAgentConversation({
    required this.controller,
    this.uiContext,
    this.compact = false,
    this.onExpand,
    super.key,
  });

  final AiAgentConversationController controller;

  /// 打开时所在的页面 / 条目（悬浮球按场景带上，spec §6.4），随每句话注入。
  final AgentUiContext? uiContext;

  /// 浮层 / 侧栏：自带一行紧凑顶栏（整页由页头承担标题）。
  final bool compact;

  /// 「展开成整页」；null = 已是整页。
  final VoidCallback? onExpand;

  /// 此刻挂着几个对话界面（浮层 / 侧栏 / 整页）。全局快捷键据此不再叠开第二层
  /// （见 `openAiAgentFromShortcut`）。
  static int get openCount => _openCount;
  static int _openCount = 0;

  @override
  State<AiAgentConversation> createState() => _AiAgentConversationState();
}

class _AiAgentConversationState extends State<AiAgentConversation> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode(debugLabel: 'ai-agent-input');
  final ScrollController _scroll = ScrollController();

  /// 用户点掉了上下文 chip：这一场不再带页面上下文。
  bool _contextDropped = false;

  /// 正在撤销的条目（按钮转圈、防连点）。
  final Set<String> _undoing = <String>{};

  /// 「附上屏幕文字」（§6.4）：附上的文字只跟下一句走。
  final AiAgentScreenTextAttachment _screenText = AiAgentScreenTextAttachment();

  AiAgentConversationController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    AiAgentConversation._openCount++;
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    AiAgentConversation._openCount--;
    _screenText.dispose();
    _controller.removeListener(_onChanged);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      unawaited(
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
        ),
      );
    });
  }

  AgentUiContext? get _activeContext =>
      _contextDropped ? null : widget.uiContext;

  Future<void> _send() async {
    final String text = _input.text.trim();
    if (text.isEmpty || _controller.running) return;
    _input.clear();
    final AiAgentScreenAttachments attached = _screenText.take();
    try {
      await _controller.send(
        text,
        context: aiAgentContextWithScreenText(_activeContext, attached.text),
        // 截图只在模型能收图时附上；发送前模型换成了不能收图的，图就不发。
        images: _controller.acceptsImages
            ? aiAgentImagesFor(attached.image)
            : const [],
      );
    } on StateError {
      if (mounted) await _guideToProviderSettings(context);
    }
    if (mounted) _inputFocus.requestFocus();
  }

  Future<void> _undo(AgentEntry entry) async {
    if (!_undoing.add(entry.id)) return;
    setState(() {});
    final AgentUndoResult result = await _controller.undoEntry(entry.id);
    _undoing.remove(entry.id);
    if (!mounted) return;
    setState(() {});
    final String? message = switch (result.status) {
      AgentUndoStatus.done => null,
      AgentUndoStatus.superseded => t.ai_agent_superseded,
      AgentUndoStatus.failed || AgentUndoStatus.notUndoable =>
        t.ai_agent_undo_failed(reason: result.message ?? result.status.name),
    };
    if (message != null) FushiToast.show(msg: message);
  }

  Future<void> _undoAll() async {
    final List<AgentUndoResult> results = await _controller.undoAll();
    if (!mounted) return;
    final int superseded = results
        .where((AgentUndoResult r) => r.status == AgentUndoStatus.superseded)
        .length;
    if (superseded > 0) FushiToast.show(msg: t.ai_agent_superseded);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<AgentEntry> entries = _controller.entries;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool tight =
            widget.compact && constraints.maxHeight < kAiAgentTightHeight;
        return _conversationColumn(context, tokens, entries, tight: tight);
      },
    );
  }

  Widget _conversationColumn(
    BuildContext context,
    FushiDesignTokens tokens,
    List<AgentEntry> entries, {
    required bool tight,
  }) {
    return Column(
      children: <Widget>[
        if (widget.compact && !tight) _compactHeader(context),
        if (!widget.compact && _controller.executorLabel != null)
          _executorBar(context),
        if (!widget.compact &&
            (_controller.undoableCount > 0 || _controller.totalTokens > 0))
          _summaryBar(context),
        Expanded(
          child: ListView(
            key: const ValueKey<String>('ai-agent-transcript'),
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
            children: <Widget>[
              if (entries.isEmpty) _emptyState(context),
              for (final AgentEntry entry in entries) _entry(context, entry),
              if (_controller.running && !_awaitingUser)
                FushiStaggeredEntrance(
                  index: 0,
                  child: Padding(
                    padding: EdgeInsets.only(top: tokens.spacing.gap),
                    child: const FushiLinearProgressIndicator(
                      key: ValueKey<String>('ai-agent-busy'),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _composer(context, tight: tight),
      ],
    );
  }

  bool get _awaitingUser =>
      _controller.awaitingConfirm || _controller.awaitingChoice;

  Widget _compactHeader(BuildContext context) {
    final int undoable = _controller.undoableCount;
    final String? executor = _controller.executorLabel;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 0),
      child: Row(
        children: <Widget>[
          const FushiIcon(FushiIcons.aiAssistant, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  t.ai_agent_title,
                  style: context.fushiType.titleMediumEmphasized,
                  overflow: TextOverflow.ellipsis,
                ),
                if (executor != null)
                  Text(
                    t.ai_video_acquire_remote_executor(device: executor),
                    key: const ValueKey<String>('ai-agent-executor'),
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ?_usageText(context, Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (undoable > 0)
            FushiTextButton(
              key: const ValueKey<String>('ai-agent-undo-all'),
              onPressed: () => unawaited(_undoAll()),
              child: Text(t.ai_agent_undo_all(n: '$undoable')),
            ),
          FushiIconButtonControl(
            key: const ValueKey<String>('ai-agent-new-session'),
            tooltip: t.ai_agent_new_session,
            onPressed: _controller.running
                ? null
                : () => unawaited(_controller.newSession()),
            icon: const FushiIcon(FushiIcons.add),
          ),
          if (widget.onExpand != null)
            FushiIconButtonControl(
              key: const ValueKey<String>('ai-agent-expand'),
              tooltip: t.ai_agent_expand,
              onPressed: widget.onExpand,
              icon: const FushiIcon(FushiIcons.openInNew),
            ),
        ],
      ),
    );
  }

  /// 整页：远端执行时在顶部写明「在 <设备> 上执行」。
  Widget _executorBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        0,
      ),
      child: Text(
        t.ai_video_acquire_remote_executor(
          device: _controller.executorLabel ?? '',
        ),
        key: const ValueKey<String>('ai-agent-executor'),
        style: Theme.of(context).textTheme.bodyMedium,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 整页顶部：本场改动数 + 用量 / 费用，「全部撤销」与「新对话」。
  Widget _summaryBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int undoable = _controller.undoableCount;
    final TextStyle? style = Theme.of(context).textTheme.bodyMedium;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (undoable > 0)
                  Text(
                    t.ai_agent_session_summary(n: '$undoable'),
                    style: style,
                  ),
                ?_usageText(context, style),
              ],
            ),
          ),
          if (undoable > 0)
            FushiTextButton(
              key: const ValueKey<String>('ai-agent-undo-all'),
              onPressed: () => unawaited(_undoAll()),
              child: Text(t.ai_agent_undo_all(n: '$undoable')),
            ),
          FushiIconButtonControl(
            key: const ValueKey<String>('ai-agent-new-session'),
            tooltip: t.ai_agent_new_session,
            onPressed: _controller.running
                ? null
                : () => unawaited(_controller.newSession()),
            icon: const FushiIcon(FushiIcons.add),
          ),
        ],
      ),
    );
  }

  /// 本场用量：「12,345 tokens · 约 $0.0123」，悬停 / 长按看输入 / 输出 / 缓存分项。
  /// 还没发过请求时为 null。费用只在执行设备的提供商填了单价时出现。
  Widget? _usageText(BuildContext context, TextStyle? style) {
    final int total = _controller.totalTokens;
    if (total <= 0) return null;
    final String locale = Intl.getCurrentLocale();
    final NumberFormat count = NumberFormat.decimalPattern(locale);
    final AiChatUsage usage = _controller.usage;
    final List<String> parts = <String>[
      t.ai_agent_tokens(n: count.format(total)),
      for (final MapEntry<String, double> cost in _controller.cost.entries)
        t.ai_agent_cost(
          amount: NumberFormat.simpleCurrency(
            locale: locale,
            name: cost.key,
            // 一场对话常常不到一分钱：小额多留几位，不显示成 $0.00。
            decimalDigits: cost.value < 1 ? 4 : 2,
          ).format(cost.value),
        ),
    ];
    return FushiTooltip(
      message: t.ai_agent_usage_breakdown(
        input: count.format(usage.inputTokens ?? 0),
        output: count.format(usage.outputTokens ?? 0),
        cacheRead: count.format(usage.cacheReadTokens ?? 0),
        cacheWrite: count.format(usage.cacheWriteTokens ?? 0),
      ),
      child: Text(
        parts.join(' · '),
        key: const ValueKey<String>('ai-agent-usage'),
        style: style?.copyWith(color: fushiNeutralSecondaryForeground(context)),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return FushiStaggeredEntrance(
      index: 0,
      child: Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const FushiListLeadingIcon(
                  FushiIcons.ai,
                  shape: FushiLeadingShape.cookie,
                  tone: FushiCardTone.primary,
                  size: 48,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    t.ai_agent_empty_title,
                    style: context.fushiType.titleLargeEmphasized,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _entry(BuildContext context, AgentEntry entry) => switch (entry.kind) {
    AgentEntryKind.user => _bubble(
      context,
      entry.text,
      fromUser: true,
      withImage: entry.imageCount > 0,
    ),
    AgentEntryKind.assistant => _bubble(context, entry.text, fromUser: false),
    AgentEntryKind.toolCall => _toolCard(context, entry),
    AgentEntryKind.confirm => _confirmCard(context, entry),
    AgentEntryKind.choice => _choiceCard(context, entry),
    AgentEntryKind.notice => _notice(context, entry),
  };

  /// 聊天气泡（与「AI 下视频」同一套配色：MD3 primaryContainer / surfaceContainerHigh，
  /// Apple 强调色 / secondaryFill，墨水屏描边）。模型的回复按 Markdown 渲染（模型
  /// 几乎都用 `**粗体**` / 列表 / 引用排版），用户自己说的话原样显示。
  Widget _bubble(
    BuildContext context,
    String text, {
    required bool fromUser,
    bool withImage = false,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final Color fill = eink
        ? scheme.surface
        : glass
        ? (fromUser ? apple.accent : apple.secondaryFill)
        : (fromUser ? scheme.primaryContainer : scheme.surfaceContainerHigh);
    final Color foreground = eink
        ? scheme.onSurface
        : glass
        ? (fromUser ? apple.onAccent : apple.label)
        : (fromUser ? scheme.onPrimaryContainer : scheme.onSurface);
    const Radius big = Radius.circular(22);
    const Radius tail = Radius.circular(6);
    return FushiStaggeredEntrance(
      index: 0,
      child: Align(
        alignment: fromUser
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadiusDirectional.only(
                  topStart: big,
                  topEnd: big,
                  bottomStart: fromUser ? big : tail,
                  bottomEnd: fromUser ? tail : big,
                ),
                border: eink ? Border.all(color: scheme.onSurface) : null,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                child: fromUser
                    ? _userText(context, text, foreground, withImage)
                    : AiAgentMarkdown(text: text, color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _userText(
    BuildContext context,
    String text,
    Color foreground,
    bool withImage,
  ) {
    final TextTheme theme = Theme.of(context).textTheme;
    final Widget body = SelectableText(
      text,
      style: theme.bodyLarge?.copyWith(color: foreground, height: 1.35),
    );
    if (!withImage) return body;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(FushiIcons.image, size: 14, color: foreground),
            const SizedBox(width: 4),
            Text(
              t.ai_agent_message_image_attached,
              style: theme.labelMedium?.copyWith(color: foreground),
            ),
          ],
        ),
        const SizedBox(height: 2),
        body,
      ],
    );
  }

  /// 一次工具调用：图标 + 操作 id + 状态 / 改前改后；可撤销的带「撤销」。
  Widget _toolCard(BuildContext context, AgentEntry entry) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final (IconData icon, Color color) = switch (entry.status) {
      AgentEntryStatus.running => (FushiIcons.sync, scheme.primary),
      AgentEntryStatus.done => (FushiIcons.check, scheme.primary),
      AgentEntryStatus.undone ||
      AgentEntryStatus.superseded => (FushiIcons.undo, scheme.outline),
      AgentEntryStatus.declined => (FushiIcons.close, scheme.outline),
      _ => (FushiIcons.error, scheme.error),
    };
    final String status = switch (entry.status) {
      AgentEntryStatus.running => t.ai_agent_tool_running,
      AgentEntryStatus.undone => t.ai_agent_undone,
      AgentEntryStatus.superseded => t.ai_agent_superseded,
      AgentEntryStatus.declined => t.ai_agent_tool_declined,
      AgentEntryStatus.failed => t.ai_agent_tool_failed(
        code: entry.errorCode ?? '',
      ),
      _ =>
        entry.before != null || entry.after != null
            ? '${entry.before ?? '∅'} → ${entry.after ?? '∅'}'
            : '',
    };
    final bool undoing = _undoing.contains(entry.id);
    final bool taskRunning = entry.taskState == 'running';
    return FushiStaggeredEntrance(
      index: 0,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FushiCard(
          key: ValueKey<String>('ai-agent-tool-${entry.id}'),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
          pressScale: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  FushiIcon(icon, size: 18, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          entry.toolName ?? '',
                          style: text.labelLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (status.isNotEmpty)
                          Text(
                            status,
                            style: text.bodySmall,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (entry.resultPreview != null || entry.arguments.isNotEmpty)
                    FushiIconButtonControl(
                      tooltip: t.ai_agent_details,
                      onPressed: () => unawaited(_showDetails(context, entry)),
                      icon: const FushiIcon(FushiIcons.info, size: 18),
                    ),
                  if (entry.canUndo)
                    FushiTextButton(
                      key: ValueKey<String>('ai-agent-undo-${entry.id}'),
                      onPressed: undoing ? null : () => unawaited(_undo(entry)),
                      child: Text(t.ai_agent_undo),
                    ),
                ],
              ),
              // 长任务还在跑：卡片底部一条不定进度条，结束后自动续一轮（spec §6.1）。
              FushiAnimatedSize(
                duration: fushiMotionDuration(context, FushiMotion.short),
                curve: FushiMotion.standard,
                child: taskRunning
                    ? Padding(
                        padding: const EdgeInsetsDirectional.only(
                          top: 6,
                          end: 8,
                        ),
                        child: FushiLinearProgressIndicator(
                          key: ValueKey<String>('ai-agent-task-${entry.id}'),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDetails(BuildContext context, AgentEntry entry) {
    const JsonEncoder pretty = JsonEncoder.withIndent('  ');
    return adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: SelectableText(
            '${entry.toolName}\n\n'
            '${pretty.convert(entry.arguments)}'
            '${entry.resultPreview == null ? '' : '\n\n${entry.resultPreview}'}',
            style: Theme.of(
              sheetContext,
            ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ),
      ),
    );
  }

  /// 确认卡片：写清后果，只有用户点了「执行」运行时才注入表态参数。
  Widget _confirmCard(BuildContext context, AgentEntry entry) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool install = _kExtensionInstallOp.hasMatch(entry.toolName ?? '');
    final bool irreversible = entry.risk == AgentToolRisk.irreversible;
    final bool pending =
        entry.status == AgentEntryStatus.pending &&
        _controller.awaitingConfirm &&
        identical(_lastPending(AgentEntryKind.confirm), entry);
    return FushiStaggeredEntrance(
      index: 0,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FushiCard(
          key: ValueKey<String>('ai-agent-confirm-${entry.id}'),
          pressScale: false,
          tone: FushiCardTone.primary,
          borderColor: irreversible ? scheme.error : null,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                install
                    ? t.ai_agent_confirm_install_title
                    : t.ai_agent_confirm_title,
                style: text.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(entry.toolName ?? '', style: text.labelLarge),
              for (final MapEntry<String, Object?> arg
                  in entry.arguments.entries)
                Text(
                  '${arg.key}: ${arg.value is String ? arg.value : jsonEncode(arg.value)}',
                  style: text.bodySmall,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: 6),
              Text(
                irreversible
                    ? t.ai_agent_confirm_irreversible
                    : t.ai_agent_confirm_undoable,
                style: text.bodySmall?.copyWith(
                  color: irreversible ? scheme.error : null,
                ),
              ),
              const SizedBox(height: 8),
              if (pending)
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    FushiFilledButton(
                      key: const ValueKey<String>('ai-agent-confirm-approve'),
                      onPressed: () => _controller.answerConfirm(true),
                      child: Text(t.ai_agent_confirm_approve),
                    ),
                    FushiTextButton(
                      key: const ValueKey<String>('ai-agent-confirm-decline'),
                      onPressed: () => _controller.answerConfirm(false),
                      child: Text(t.ai_agent_confirm_decline),
                    ),
                  ],
                )
              else
                Text(
                  entry.status == AgentEntryStatus.approved
                      ? t.ai_agent_confirm_approved
                      : t.ai_agent_confirm_declined,
                  style: text.labelMedium,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 候选卡片（`ui.ask_choice`）：用户点选比模型猜更可靠（spec §6.2）。
  Widget _choiceCard(BuildContext context, AgentEntry entry) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool pending =
        entry.status == AgentEntryStatus.pending &&
        _controller.awaitingChoice &&
        identical(_lastPending(AgentEntryKind.choice), entry);
    String labelOf(String? id) {
      for (final AgentChoiceOption o in entry.options) {
        if (o.id == id) return o.label;
      }
      return id ?? '';
    }

    return FushiStaggeredEntrance(
      index: 0,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (entry.text.isNotEmpty)
              _bubble(context, entry.text, fromUser: false),
            const SizedBox(height: 6),
            if (pending)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  // 选项是整行可换行的条目而不是 chip：chip 只排一行，字幕文件名、
                  // 作品名这类长标签会被裁掉右半截、看不出区别。
                  for (final AgentChoiceOption option in entry.options)
                    _AgentChoiceOptionTile(
                      key: ValueKey<String>('ai-agent-choice-${option.id}'),
                      option: option,
                      onPressed: () => _controller.answerChoice(option.id),
                    ),
                  FushiActionChipControl(
                    key: const ValueKey<String>('ai-agent-choice-cancel'),
                    avatar: const FushiIcon(FushiIcons.close, size: 16),
                    label: Text(t.ai_agent_choice_cancel),
                    onPressed: () => _controller.answerChoice(null),
                  ),
                ],
              )
            else
              Text(
                entry.selected == null
                    ? t.ai_agent_choice_cancel
                    : t.ai_agent_choice_picked(label: labelOf(entry.selected)),
                style: text.labelMedium,
              ),
          ],
        ),
      ),
    );
  }

  AgentEntry? _lastPending(AgentEntryKind kind) {
    final List<AgentEntry> entries = _controller.entries;
    for (int i = entries.length - 1; i >= 0; i--) {
      if (entries[i].kind == kind) return entries[i];
    }
    return null;
  }

  Widget _notice(BuildContext context, AgentEntry entry) {
    final String message = switch (entry.errorCode) {
      AgentStopCode.toolLimit => t.ai_agent_stop_tool_limit,
      AgentStopCode.repeatedFailure => t.ai_agent_stop_repeated_failure,
      AgentStopCode.tokenBudget => t.ai_agent_stop_token_budget,
      AgentStopCode.llmError => t.ai_agent_stop_llm_error(
        reason: aiFailureText(entry.text),
      ),
      AgentStopCode.cancelled => t.ai_agent_stop_cancelled,
      kAiAgentRemoteUnavailableCode => t.ai_agent_remote_lost,
      AgentStopCode.taskFinished =>
        entry.status == AgentEntryStatus.done
            ? t.ai_agent_task_done(
                op: entry.toolName ?? '',
                summary: entry.text,
              )
            : t.ai_agent_task_failed(
                op: entry.toolName ?? '',
                summary: entry.text,
              ),
      _ => entry.text,
    };
    return FushiStaggeredEntrance(
      index: 0,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Center(
          child: Text(
            message,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  /// 输入栏（上下文 chip + 输入框 + 发送 / 停止）。
  ///
  /// MD3 下是**一层**悬浮面板：chip、输入框、按钮都直接放在面板上，输入框不再另套
  /// 一层不同底色的圆角框（面板套面板显得臃肿），按钮贴底对齐（多行输入时不悬在
  /// 中间）。Apple / 墨水屏没有外层面板，输入框自己带底色 / 描边。
  Widget _composer(BuildContext context, {bool tight = false}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final bool panel = !glass && !eink;
    final bool running = _controller.running;
    final bool acceptsImages = _controller.acceptsImages;
    final AgentUiContext? uiContext = _activeContext;
    final String? contextTitle =
        uiContext?.itemTitle ?? _contextPageLabel(uiContext?.page);
    final Widget field = FushiTextFieldControl(
      key: const ValueKey<String>('ai-agent-input'),
      controller: _input,
      focusNode: _inputFocus,
      enabled: !running,
      autofocus: true,
      minLines: 1,
      maxLines: 4,
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => unawaited(_send()),
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: t.ai_agent_input_hint,
        border: InputBorder.none,
        filled: false,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(
          horizontal: panel ? 8 : 20,
          vertical: 14,
        ),
      ),
    );
    final Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        // 浮层 / 侧栏才有：截图时把面板藏掉就露出下面的页面；整页外壳下面也是
        // 不透明路由，截不到别的。
        if (widget.compact &&
            (screenTextCaptureSupported || acceptsImages)) ...<Widget>[
          AiAgentScreenTextButton(
            attachment: _screenText,
            enabled: !running,
            keepImage: acceptsImages,
          ),
          if (!panel) SizedBox(width: tokens.spacing.gap / 2),
        ] else if (panel)
          const SizedBox(width: 12),
        Expanded(
          child: panel
              ? field
              : DecoratedBox(
                  decoration: BoxDecoration(
                    color: eink ? scheme.surface : scheme.surfaceContainerHigh,
                    borderRadius: FushiBorderRadius.dialog,
                    border: eink ? Border.all(color: scheme.onSurface) : null,
                  ),
                  child: field,
                ),
        ),
        SizedBox(width: panel ? 4 : tokens.spacing.gap),
        if (running)
          FushiIconButtonControl(
            key: const ValueKey<String>('ai-agent-stop'),
            tooltip: t.ai_agent_stop,
            onPressed: _controller.cancel,
            icon: const FushiIcon(FushiIcons.stop),
          )
        else
          FushiIconButtonControl.filled(
            key: const ValueKey<String>('ai-agent-send'),
            tooltip: t.ai_agent_send,
            onPressed: () => unawaited(_send()),
            icon: FushiIcon(
              glass ? CupertinoIcons.arrow_up : FushiIcons.forward,
            ),
          ),
      ],
    );
    final Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: panel
              ? const EdgeInsets.fromLTRB(6, 4, 6, 0)
              : EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (!tight) AiAgentScreenTextChip(attachment: _screenText),
              if (contextTitle != null && !tight)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2, left: 4),
                  child: FushiInputChip(
                    key: const ValueKey<String>('ai-agent-context-chip'),
                    label: Text(t.ai_agent_context_chip(title: contextTitle)),
                    onDeleted: () => setState(() => _contextDropped = true),
                  ),
                ),
            ],
          ),
        ),
        row,
      ],
    );
    final EdgeInsets outer = EdgeInsets.fromLTRB(
      tokens.spacing.page,
      tokens.spacing.gap,
      tokens.spacing.page,
      tokens.spacing.gap + bottomSafeInsetOf(context),
    );
    if (!panel) return Padding(padding: outer, child: body);
    return Padding(
      padding: outer,
      child: DecoratedBox(
        decoration: fushiFloatingPillDecoration(
          context,
          color: scheme.surfaceContainerHigh,
          shape: const RoundedRectangleBorder(
            borderRadius: FushiBorderRadius.dialog,
          ),
        ),
        child: Padding(padding: const EdgeInsets.all(4), child: body),
      ),
    );
  }

  /// 上下文 chip 里的页面名：库页页头「问 AI」给的是内部页面键，换成用户看得懂
  /// 的页面标题；认不出的键原样显示。
  static String? _contextPageLabel(String? page) => switch (page) {
    null => null,
    'books' => t.books,
    'manga_library' => t.manga_library,
    'video_library' => t.nav_video,
    'games_library' => t.nav_game,
    final String other => other,
  };
}

/// 模型回复的 Markdown 渲染（粗体 / 列表 / 引用 / 代码 / 链接）。可选中复制；
/// 链接在外部浏览器打开。字号、行高与用户气泡一致，颜色跟随气泡前景色。
class AiAgentMarkdown extends StatelessWidget {
  const AiAgentMarkdown({required this.text, required this.color, super.key});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final TextTheme theme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? body = theme.bodyLarge?.copyWith(
      color: color,
      height: 1.35,
    );
    return MarkdownBody(
      data: text,
      selectable: true,
      // flutter_markdown 0.6.23 在 selectable 时会无条件解引用
      // onSelectionChanged!，不传则选中文本即崩（TODO-966，与更新日志页同一约定）。
      onSelectionChanged:
          (
            String? text,
            TextSelection selection,
            SelectionChangedCause? cause,
          ) {},
      onTapLink: (String _, String? href, String _) {
        final Uri? uri = href == null ? null : Uri.tryParse(href);
        if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
          return;
        }
        unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
      },
      // 只给要改的样式：flutter_markdown 自己把它并到回退样式表上（回退样式表
      // 读的是 LegacyDesignCompatibility 桥出来的旧主题），这里不必碰旧 SDK 类型。
      styleSheet: MarkdownStyleSheet(
        p: body,
        listBullet: body,
        strong: const TextStyle(fontWeight: FontWeight.w700),
        em: const TextStyle(fontStyle: FontStyle.italic),
        a: TextStyle(color: color, decoration: TextDecoration.underline),
        h1: theme.titleLarge?.copyWith(color: color),
        h2: theme.titleMedium?.copyWith(color: color),
        h3: theme.titleSmall?.copyWith(color: color),
        code: theme.bodyMedium?.copyWith(
          color: color,
          fontFamily: 'monospace',
          backgroundColor: scheme.surfaceContainerHighest,
        ),
        codeblockDecoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: FushiBorderRadius.card,
        ),
        blockquote: body,
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: scheme.outlineVariant, width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 10),
        pPadding: EdgeInsets.zero,
        blockSpacing: 8,
      ),
    );
  }
}

/// 候选卡里的一个选项：整行宽、标签与说明完整换行**不截断**（文件名之间常只差
/// 结尾几个字，截掉就分不清；超长无空格的串按字符折行，不会横向溢出）。
class _AgentChoiceOptionTile extends StatelessWidget {
  const _AgentChoiceOptionTile({
    required this.option,
    required this.onPressed,
    super.key,
  });

  final AgentChoiceOption option;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool eink = isEinkTheme(context);
    final bool glass = isGlassDesign(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final Color fill = eink
        ? scheme.surface
        : glass
        ? apple.secondaryFill
        : scheme.surfaceContainerHigh;
    final Color foreground = glass && !eink ? apple.label : scheme.onSurface;
    final String? detail = option.detail;
    const BorderRadius radius = FushiM3eShape.cardRadius;
    return FushiPressScale(
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: eink ? BorderSide(color: scheme.outline) : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: 48,
              minWidth: double.infinity,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    option.label,
                    style: text.bodyMedium?.copyWith(color: foreground),
                  ),
                  if (detail != null && detail.isNotEmpty)
                    Text(
                      detail,
                      style: text.labelSmall?.copyWith(
                        color: glass && !eink
                            ? apple.secondaryLabel
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
