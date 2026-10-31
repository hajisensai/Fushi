import 'dart:async';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// AI 操作记录（spec `docs/specs/2026-10-26-ai-operations-agent-design.md` §5.3）：
/// AI 助手历次会话做过的写操作，过了会话也能逐条 / 整场撤销，也能接着某场对话说。
/// 与库整理的「整理记录」同一形态；记录设备本地，保留 30 天（D3）。
Future<void> openAiAgentHistoryPage(BuildContext context, AppModel appModel) =>
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => AiAgentHistoryPage(db: appModel.database),
      ),
    );

class AiAgentHistoryPage extends StatefulWidget {
  const AiAgentHistoryPage({required this.db, this.controller, super.key});

  final FushiDatabase db;

  /// 撤销与「继续对话」用的控制器；null = app 内唯一实例。
  final AiAgentController? controller;

  @override
  State<AiAgentHistoryPage> createState() => _AiAgentHistoryPageState();
}

class _SessionView {
  _SessionView(this.id, this.title, this.actions);

  final String id;
  final String? title;
  final List<AiAgentActionRow> actions;
}

class _AiAgentHistoryPageState extends State<AiAgentHistoryPage> {
  List<_SessionView> _sessions = const <_SessionView>[];
  bool _loading = true;
  bool _busy = false;
  int _generation = 0;

  AiAgentController? get _controller =>
      widget.controller ?? AiAgentController.instanceOrNull;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final List<AiAgentActionRow> actions = await widget.db.listAiAgentActions(
      limit: 500,
    );
    final Map<String, String> titles = <String, String>{
      // 操作记录不分 Profile，标题也按全部 Profile 的会话配。
      for (final AiAgentSessionSummary s
          in await widget.db.listAiAgentSessionSummaries(limit: 200))
        s.id: s.title,
    };
    final Map<String, List<AiAgentActionRow>> bySession =
        <String, List<AiAgentActionRow>>{};
    for (final AiAgentActionRow a in actions) {
      // 读操作不落记录；失败的写操作也列出来（知道 AI 试过什么），但不能撤销。
      bySession.putIfAbsent(a.sessionId, () => <AiAgentActionRow>[]).add(a);
    }
    if (!mounted) return;
    setState(() {
      _sessions = <_SessionView>[
        for (final MapEntry<String, List<AiAgentActionRow>> e
            in bySession.entries)
          _SessionView(e.key, titles[e.key], e.value),
      ];
      _loading = false;
      _generation++;
    });
  }

  Future<void> _undo(List<AiAgentActionRow> rows) async {
    final AiAgentController? controller = _controller;
    if (controller == null || _busy) return;
    setState(() => _busy = true);
    int superseded = 0;
    String? failure;
    try {
      // 倒序撤销（spec §5.3）：rows 已按时间倒序。
      for (final AiAgentActionRow row in rows) {
        if (!_undoable(row)) continue;
        final AgentUndoResult result = await controller.toolbox.undo(
          '${row.id}',
        );
        if (result.status == AgentUndoStatus.superseded) superseded++;
        if (result.status == AgentUndoStatus.failed) {
          failure ??= result.message ?? row.opId;
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (failure != null) {
      FushiToast.show(msg: t.ai_agent_undo_failed(reason: failure));
    } else if (superseded > 0) {
      FushiToast.show(msg: t.ai_agent_superseded);
    }
    await _load();
  }

  Future<void> _resume(String sessionId) async {
    final AiAgentController? controller = _controller;
    if (controller == null) return;
    if (!await controller.resume(sessionId) || !mounted) return;
    await pushAiAgentPage(context);
  }

  static bool _undoable(AiAgentActionRow row) =>
      row.undoPayloadJson != null && row.undoneAt == null;

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.ai_agent_history_title,
      body: _loading
          ? const Center(child: FushiCircularProgressIndicator())
          : _sessions.isEmpty
          ? Center(child: Text(t.ai_agent_history_empty))
          : _buildList(context),
    );
  }

  Widget _buildList(BuildContext context) {
    const EdgeInsets groupPadding = EdgeInsets.symmetric(horizontal: 16);
    int order = 0;
    return FushiEntranceScope(
      replayKey: _generation,
      child: ListView(
        key: const ValueKey<String>('ai_agent_history_list'),
        padding: EdgeInsets.only(
          top: 8 + MediaQuery.paddingOf(context).top,
          bottom: 24 + bottomSafeInsetOf(context),
        ),
        children: <Widget>[
          for (final _SessionView session in _sessions) ...<Widget>[
            _sessionHeader(session),
            FushiStaggeredEntrance(
              index: order++,
              child: FushiGroupedList(
                padding: groupPadding,
                children: <Widget>[
                  for (final AiAgentActionRow row in session.actions)
                    _actionTile(row),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sessionHeader(_SessionView session) {
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(
      session.actions.last.createdAt,
    );
    final int live = session.actions.where(_undoable).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 16, 16, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '${MaterialLocalizations.of(context).formatShortDate(at)} '
              '${TimeOfDay.fromDateTime(at).format(context)}'
              '${session.title == null ? '' : ' · ${session.title}'}',
              style: Theme.of(context).textTheme.labelLarge,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (session.title != null)
            FushiTextButton(
              key: ValueKey<String>('ai_agent_history_resume_${session.id}'),
              onPressed: _busy ? null : () => unawaited(_resume(session.id)),
              child: Text(t.ai_agent_history_resume),
            ),
          if (live > 0)
            FushiTextButton(
              key: ValueKey<String>('ai_agent_history_undo_all_${session.id}'),
              onPressed: _busy ? null : () => unawaited(_undo(session.actions)),
              child: Text(t.ai_agent_undo_all(n: '$live')),
            ),
        ],
      ),
    );
  }

  Widget _actionTile(AiAgentActionRow row) {
    final bool failed = row.resultCode != 'ok';
    final String status = row.undoneAt != null
        ? (row.undoStatus == 'superseded'
              ? t.ai_agent_superseded
              : t.ai_agent_undone)
        : failed
        ? t.ai_agent_tool_failed(code: row.resultCode)
        : row.beforeText != null || row.afterText != null
        ? '${row.beforeText ?? '∅'} → ${row.afterText ?? '∅'}'
        : row.undoPayloadJson == null
        ? t.ai_agent_risk_irreversible
        : '';
    return FushiListItem(
      key: ValueKey<String>('ai_agent_history_action_${row.id}'),
      leading: FushiListLeadingIcon(
        failed
            ? FushiIcons.error
            : row.undoneAt != null
            ? FushiIcons.undo
            : FushiIcons.check,
      ),
      title: Text(row.opId),
      subtitle: Text(
        <String>[
          if (status.isNotEmpty) status,
          if (row.confirmation == 'user') t.ai_agent_history_by_user,
        ].join(' · '),
      ),
      trailing: _undoable(row)
          ? FushiTextButton(
              key: ValueKey<String>('ai_agent_history_undo_${row.id}'),
              onPressed: _busy
                  ? null
                  : () => unawaited(_undo(<AiAgentActionRow>[row])),
              child: Text(t.ai_agent_undo),
            )
          : null,
    );
  }
}
