/// AI 助手的会话列表（反馈 uILXKiYRhl「随意切换会话、看历史会话」）：新建、切换 /
/// 续接历史会话、重命名、删除（删除先确认）。数据来自 [AiAgentSessionLibrary]
/// ——本机对话存档 `ai_agent_sessions`，按当前 Profile 过滤，保留 30 天（spec D5）。
///
/// 两种外壳共用 [AiAgentSessionList]：宽屏整页把它常驻在对话左侧；浮层 / 侧栏 /
/// 窄屏整页点「会话」按钮弹 [showAiAgentSessionsSheet]。行、分组、菜单、对话框
/// 全走设计系统组件，MD3 与 Apple 两套各自成形；列表错峰进场、按压缩放、增删时
/// 高度过渡，时长取 [FushiMotion]（减弱动态效果时归零）。
library;

import 'dart:async';

import 'package:fushi_core/fushi_core.dart' show AiAgentSessionSummary;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/agent/ai_agent_conversation_controller.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 列表里「新对话」按钮。
const ValueKey<String> kAiAgentSessionsNewKey = ValueKey<String>(
  'ai-agent-sessions-new',
);

/// 当前会话还没落库时置顶的那一行「新对话 · 当前」。
const ValueKey<String> kAiAgentSessionsDraftKey = ValueKey<String>(
  'ai-agent-sessions-draft',
);

/// 一场存档会话的行。
ValueKey<String> aiAgentSessionRowKey(String sessionId) =>
    ValueKey<String>('ai-agent-session-$sessionId');

/// 一场存档会话行尾的「会话选项」菜单按钮。
ValueKey<String> aiAgentSessionMenuKey(String sessionId) =>
    ValueKey<String>('ai-agent-session-menu-$sessionId');

/// 窄屏 / 浮层：弹出会话列表；选中 / 新建一场后自动收起。
Future<void> showAiAgentSessionsSheet(
  BuildContext context,
  AiAgentSessionLibrary library,
) => adaptiveModalSheet<void>(
  context: context,
  expandable: true,
  builder: (BuildContext sheetContext) => SizedBox(
    height: MediaQuery.sizeOf(sheetContext).height * 0.6,
    child: AiAgentSessionList(
      library: library,
      onSessionChosen: () => Navigator.of(sheetContext).pop(),
    ),
  ),
);

enum _SessionAction { rename, delete }

/// 会话列表本体：顶部「新对话」，下面是当前 Profile 的历史会话（最近更新的在前，
/// 当前这场高亮）。点一行切过去接着聊；行尾菜单重命名 / 删除。
class AiAgentSessionList extends StatefulWidget {
  const AiAgentSessionList({
    required this.library,
    this.onSessionChosen,
    super.key,
  });

  final AiAgentSessionLibrary library;

  /// 切换 / 新建成功之后（弹层用它收起自己；常驻侧栏传 null）。
  final VoidCallback? onSessionChosen;

  @override
  State<AiAgentSessionList> createState() => _AiAgentSessionListState();
}

class _AiAgentSessionListState extends State<AiAgentSessionList> {
  List<AiAgentSessionSummary>? _sessions;

  /// 进场动画只在首次载入时播；之后的增删改走高度过渡，不整列重放。
  int _generation = 0;

  /// 只认最后一次读取的结果（连着几次存档写入时旧读取晚到不能盖掉新的）。
  int _loadSeq = 0;

  /// 正在切过去的那一场（行转圈、防连点）。
  String? _switching;

  AiAgentSessionLibrary get _library => widget.library;

  @override
  void initState() {
    super.initState();
    _subscribe(_library);
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(AiAgentSessionList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.library, widget.library)) {
      _unsubscribe(oldWidget.library);
      _subscribe(widget.library);
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    _unsubscribe(_library);
    super.dispose();
  }

  void _subscribe(AiAgentSessionLibrary library) {
    library.addListener(_onLibraryChanged);
    library.sessionsRevision.addListener(_onRevision);
  }

  void _unsubscribe(AiAgentSessionLibrary library) {
    library.removeListener(_onLibraryChanged);
    library.sessionsRevision.removeListener(_onRevision);
  }

  void _onLibraryChanged() {
    if (mounted) setState(() {});
  }

  void _onRevision() => unawaited(_reload());

  Future<void> _reload() async {
    final int seq = ++_loadSeq;
    final List<AiAgentSessionSummary> sessions = await _library.listSessions();
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      if (_sessions == null) _generation++;
      _sessions = sessions;
    });
  }

  Future<void> _newSession() async {
    await _library.newSession();
    widget.onSessionChosen?.call();
  }

  Future<void> _open(AiAgentSessionSummary session) async {
    if (_switching != null) return;
    if (session.id == _library.currentSessionId) {
      widget.onSessionChosen?.call();
      return;
    }
    setState(() => _switching = session.id);
    final bool ok;
    try {
      ok = await _library.switchToSession(session.id);
    } finally {
      if (mounted) setState(() => _switching = null);
    }
    if (!ok) {
      FushiToast.show(msg: t.ai_agent_session_open_failed);
      return;
    }
    widget.onSessionChosen?.call();
  }

  Future<void> _rename(AiAgentSessionSummary session) async {
    final String? title = await showFushiTextInputDialog(
      context: context,
      title: t.ai_agent_session_rename_title,
      initialValue: _titleOf(session),
      confirmLabel: t.ai_agent_session_rename,
      cancelLabel: t.cancel,
      icon: FushiIcons.rename,
    );
    if (title == null) return;
    await _library.renameSession(session.id, title);
  }

  Future<void> _delete(AiAgentSessionSummary session) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.ai_agent_session_delete_title,
      message: t.ai_agent_session_delete_message(title: _titleOf(session)),
      confirmLabel: t.ai_agent_session_delete,
      cancelLabel: t.cancel,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!confirmed) return;
    await _library.deleteSession(session.id);
  }

  static String _titleOf(AiAgentSessionSummary session) =>
      session.title.isEmpty ? t.ai_agent_new_session : session.title;

  String _timeOf(BuildContext context, int at) {
    final DateTime time = DateTime.fromMillisecondsSinceEpoch(at);
    final DateTime now = DateTime.now();
    final String clock = TimeOfDay.fromDateTime(time).format(context);
    if (time.year == now.year &&
        time.month == now.month &&
        time.day == now.day) {
      return clock;
    }
    return '${MaterialLocalizations.of(context).formatShortDate(time)} $clock';
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            tokens.spacing.page,
            tokens.spacing.gap,
            tokens.spacing.page,
            tokens.spacing.gap,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.ai_agent_sessions_title,
                  style: context.fushiType.titleMediumEmphasized,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              FushiPressScale(
                enabled: !_library.running,
                child: FushiFilledButton.tonal(
                  key: kAiAgentSessionsNewKey,
                  onPressed: _library.running
                      ? null
                      : () => unawaited(_newSession()),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const FushiIcon(FushiIcons.add, size: 18),
                      const SizedBox(width: 6),
                      Text(t.ai_agent_new_session),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _body(context, tokens)),
      ],
    );
  }

  Widget _body(BuildContext context, FushiDesignTokens tokens) {
    final List<AiAgentSessionSummary>? sessions = _sessions;
    if (sessions == null) {
      return const Center(child: FushiCircularProgressIndicator());
    }
    final bool draft = _library.currentSessionUnsaved;
    final List<Widget> rows = <Widget>[
      if (draft)
        FushiStaggeredEntrance(
          key: kAiAgentSessionsDraftKey,
          index: 0,
          child: FushiListItem(
            selected: true,
            leading: const FushiListLeadingIcon(FushiIcons.add),
            title: Text(t.ai_agent_new_session),
            subtitle: Text(t.ai_agent_session_current),
          ),
        ),
      for (int i = 0; i < sessions.length; i++)
        FushiStaggeredEntrance(
          key: aiAgentSessionRowKey(sessions[i].id),
          index: i + (draft ? 1 : 0),
          child: _row(context, sessions[i]),
        ),
    ];
    final TextStyle? hintStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: fushiNeutralSecondaryForeground(context));
    return FushiEntranceScope(
      replayKey: _generation,
      child: ListView(
        key: const ValueKey<String>('ai-agent-sessions-list'),
        padding: EdgeInsets.only(bottom: 16 + bottomSafeInsetOf(context)),
        children: <Widget>[
          FushiAnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.standard,
            alignment: Alignment.topCenter,
            child: rows.isEmpty
                ? Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: tokens.spacing.page,
                      vertical: 24,
                    ),
                    child: Text(
                      t.ai_agent_sessions_empty,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : FushiGroupedList(
                    padding: EdgeInsets.symmetric(
                      horizontal: tokens.spacing.page,
                    ),
                    children: rows,
                  ),
          ),
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              tokens.spacing.page + 4,
              tokens.spacing.gap,
              tokens.spacing.page,
              0,
            ),
            child: Text(t.ai_agent_sessions_retention_hint, style: hintStyle),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, AiAgentSessionSummary session) {
    final bool current = session.id == _library.currentSessionId;
    final bool switching = _switching == session.id;
    final bool locked = _library.running && !current;
    return FushiPressScale(
      enabled: !locked,
      child: FushiListItem(
        selected: current,
        leading: const FushiListLeadingIcon(FushiIcons.forum),
        title: Text(_titleOf(session)),
        subtitle: Text(
          <String>[
            _timeOf(context, session.updatedAt),
            if (current) t.ai_agent_session_current,
          ].join(' · '),
        ),
        onTap: locked ? null : () => unawaited(_open(session)),
        trailing: switching
            ? const SizedBox.square(
                dimension: 24,
                child: FushiCircularProgressIndicator(strokeWidth: 2),
              )
            : FushiPopupMenuButton<_SessionAction>(
                key: aiAgentSessionMenuKey(session.id),
                tooltip: t.ai_agent_session_more,
                icon: const FushiIcon(FushiIcons.more),
                onSelected: (_SessionAction action) =>
                    unawaited(switch (action) {
                      _SessionAction.rename => _rename(session),
                      _SessionAction.delete => _delete(session),
                    }),
                itemBuilder: (BuildContext _) =>
                    <PopupMenuEntry<_SessionAction>>[
                      _menuItem(
                        _SessionAction.rename,
                        FushiIcons.rename,
                        t.ai_agent_session_rename,
                      ),
                      _menuItem(
                        _SessionAction.delete,
                        FushiIcons.delete,
                        t.ai_agent_session_delete,
                      ),
                    ],
              ),
      ),
    );
  }

  PopupMenuItem<_SessionAction> _menuItem(
    _SessionAction value,
    IconData icon,
    String label,
  ) => PopupMenuItem<_SessionAction>(
    value: value,
    child: Row(
      children: <Widget>[
        FushiIcon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    ),
  );
}
