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
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/ai/agent/ai_agent_in_process_ops.dart';
import 'package:fushi/src/ops/app_op_context.dart';
import 'package:fushi/src/pages/implementations/ai_provider_settings_section.dart'
    show aiFailureText;
import 'package:fushi/src/pages/implementations/ai_settings_route.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show fushiFloatingPillDecoration;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 侧栏 / 浮层判宽阈值：宽于它的窗口用靠边侧栏，窄的用底部半屏面板。
const double kAiAgentSidePanelBreakpoint = 840;

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
  final AiAgentController? controller = AiAgentController.instanceOrNull;
  if (controller == null) return;
  if (!controller.hasProvider) {
    await _guideToProviderSettings(context);
    return;
  }
  if (!context.mounted) return;
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
  final AiAgentController? controller = AiAgentController.instanceOrNull;
  if (controller == null) return;
  if (!controller.hasProvider) {
    await _guideToProviderSettings(context);
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext _) =>
          AiAgentPage(controller: controller, uiContext: uiContext),
    ),
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
  AiAgentController controller,
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
          return Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Material(
                color: scheme.surfaceContainerLow,
                elevation: 6,
                borderRadius: BorderRadius.circular(28),
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

  final AiAgentController controller;
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

  final AiAgentController controller;

  /// 打开时所在的页面 / 条目（悬浮球按场景带上，spec §6.4），随每句话注入。
  final AgentUiContext? uiContext;

  /// 浮层 / 侧栏：自带一行紧凑顶栏（整页由页头承担标题）。
  final bool compact;

  /// 「展开成整页」；null = 已是整页。
  final VoidCallback? onExpand;

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

  AiAgentController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.host.pending.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.host.pending.removeListener(_onChanged);
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
    try {
      await _controller.send(text, context: _activeContext);
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
    final AgentSession? session = _controller.session;
    final List<AgentEntry> entries = session?.entries ?? const <AgentEntry>[];
    return Column(
      children: <Widget>[
        if (widget.compact) _compactHeader(context, session),
        if (!widget.compact && session != null && session.undoableCount > 0)
          _summaryBar(context, session),
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
        _composer(context),
      ],
    );
  }

  bool get _awaitingUser =>
      _controller.host.awaitingConfirm || _controller.host.awaitingChoice;

  Widget _compactHeader(BuildContext context, AgentSession? session) {
    final int undoable = session?.undoableCount ?? 0;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 0),
      child: Row(
        children: <Widget>[
          const FushiIcon(FushiIcons.aiAssistant, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.ai_agent_title,
              style: context.fushiType.titleMediumEmphasized,
              overflow: TextOverflow.ellipsis,
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

  Widget _summaryBar(BuildContext context, AgentSession session) {
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
            child: Text(
              '${t.ai_agent_session_summary(n: '${session.undoableCount}')}'
              ' · ${t.ai_agent_tokens(n: '${session.totalTokens}')}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          FushiTextButton(
            key: const ValueKey<String>('ai-agent-undo-all'),
            onPressed: () => unawaited(_undoAll()),
            child: Text(t.ai_agent_undo_all(n: '${session.undoableCount}')),
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
            const SizedBox(height: 12),
            Text(
              t.ai_agent_empty_examples,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _entry(BuildContext context, AgentEntry entry) => switch (entry.kind) {
    AgentEntryKind.user => _bubble(context, entry.text, fromUser: true),
    AgentEntryKind.assistant => _bubble(context, entry.text, fromUser: false),
    AgentEntryKind.toolCall => _toolCard(context, entry),
    AgentEntryKind.confirm => _confirmCard(context, entry),
    AgentEntryKind.choice => _choiceCard(context, entry),
    AgentEntryKind.notice => _notice(context, entry),
  };

  /// 聊天气泡（与「AI 下视频」同一套配色：MD3 primaryContainer / surfaceContainerHigh，
  /// Apple 强调色 / secondaryFill，墨水屏描边）。
  Widget _bubble(BuildContext context, String text, {required bool fromUser}) {
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
                child: SelectableText(
                  text,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: foreground,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
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
    return FushiStaggeredEntrance(
      index: 0,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FushiCard(
          key: ValueKey<String>('ai-agent-tool-${entry.id}'),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
          pressScale: false,
          child: Row(
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
        _controller.host.awaitingConfirm &&
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
                      onPressed: () => _controller.host.answerConfirm(true),
                      child: Text(t.ai_agent_confirm_approve),
                    ),
                    FushiTextButton(
                      key: const ValueKey<String>('ai-agent-confirm-decline'),
                      onPressed: () => _controller.host.answerConfirm(false),
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
        _controller.host.awaitingChoice &&
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
                  for (final AgentChoiceOption option in entry.options)
                    FushiActionChipControl(
                      key: ValueKey<String>('ai-agent-choice-${option.id}'),
                      label: Text(
                        option.detail == null
                            ? option.label
                            : '${option.label} · ${option.detail}',
                      ),
                      onPressed: () => _controller.host.answerChoice(option.id),
                    ),
                  FushiActionChipControl(
                    key: const ValueKey<String>('ai-agent-choice-cancel'),
                    avatar: const FushiIcon(FushiIcons.close, size: 16),
                    label: Text(t.ai_agent_choice_cancel),
                    onPressed: () => _controller.host.answerChoice(null),
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
    final List<AgentEntry> entries =
        _controller.session?.entries ?? const <AgentEntry>[];
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

  /// 输入栏（上下文 chip + 输入胶囊 + 发送 / 停止）。
  Widget _composer(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final bool running = _controller.running;
    final AgentUiContext? uiContext = _activeContext;
    final String? contextTitle = uiContext?.itemTitle ?? uiContext?.page;
    final Widget row = Row(
      children: <Widget>[
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isEinkTheme(context)
                  ? scheme.surface
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(28),
              border: isEinkTheme(context)
                  ? Border.all(color: scheme.onSurface)
                  : null,
            ),
            child: FushiTextFieldControl(
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
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: tokens.spacing.gap),
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
        if (contextTitle != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: FushiInputChip(
              key: const ValueKey<String>('ai-agent-context-chip'),
              label: Text(t.ai_agent_context_chip(title: contextTitle)),
              onDeleted: () => setState(() => _contextDropped = true),
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
    if (glass || isEinkTheme(context)) {
      return Padding(padding: outer, child: body);
    }
    return Padding(
      padding: outer,
      child: DecoratedBox(
        decoration: fushiFloatingPillDecoration(
          context,
          color: scheme.surfaceContainer,
        ),
        child: Padding(padding: const EdgeInsets.all(6), child: body),
      ),
    );
  }
}
