import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';

import 'package:fushi/src/ai/agent/ai_agent_skills.dart';

/// 常驻工具（spec §6.1：约 15 个，每轮都带上）；其余经 `ops.search` → `ops.describe`
/// 现取。只列目录里真实存在的 id，不存在的（当前平台没这条路由）静默跳过。
const List<String> kAiAgentResidentOps = <String>[
  'settings.search',
  'settings.get',
  'settings.set',
  'modules.list',
  'nav.open',
  'library.search',
  'video.library.list',
  'downloads.list',
  'tasks.list',
  'tasks.get',
];

/// 长任务结束的回调（会话 id、操作 id、任务 id、最终状态）。
typedef AiAgentTaskFinished =
    void Function(
      String sessionId,
      String opId,
      String taskId,
      OpTaskStatus status,
    );

/// 参数里看起来像凭据的键：记账前抹掉（spec §5.3「参数（剔除凭据）」）。
final RegExp _kSecretKey = RegExp(
  r'(api_?key|token|secret|password|passwd|cookie|authorization|credential)',
  caseSensitive: false,
);

/// 结果里「这一项是凭据」的标题 / 键名（含中日文）：源偏好、表单项这类
/// `{key, title, value}` 形状的条目按它判，值换成 `<redacted>`。
final RegExp _kSecretLabel = RegExp(
  r'(password|passwd|passcode|api[ _-]?key|token|secret|cookie|credential|密码|密碼|口令|パスワード|トークン)',
  caseSensitive: false,
);

/// 交给模型前抹掉结果里的凭据（spec §4.3 / §10：AI 不可读凭据）。递归处理：
/// 键名像凭据的值整体抹掉；`{key/title/name, value}` 形状的条目按其标题判。
Object? redactAiAgentResult(Object? data) {
  if (data is List) {
    return <Object?>[for (final Object? e in data) redactAiAgentResult(e)];
  }
  if (data is! Map) return data;
  final Map<String, Object?> map = <String, Object?>{
    for (final MapEntry<Object?, Object?> e in data.entries)
      '${e.key}': e.value,
  };
  final bool labelledSecret = <Object?>[
    map['key'],
    map['title'],
    map['name'],
    map['label'],
  ].any((Object? v) => v is String && _kSecretLabel.hasMatch(v));
  return <String, Object?>{
    for (final MapEntry<String, Object?> e in map.entries)
      e.key: _kSecretKey.hasMatch(e.key) && e.value is! Map && e.value is! List
          ? '<redacted>'
          : labelledSecret && e.key == 'value'
          ? '<redacted>'
          : redactAiAgentResult(e.value),
  };
}

/// 把操作目录适配成 AI 助手的工具箱（spec §5、§6）。
///
/// - 只暴露带描述、当前可用的操作；`irreversible` / `confirm` 的由 agent loop 先
///   出确认卡片，这里按 [AgentToolInvocation.confirmed] 注入表态参数；可撤销操作
///   直接注入（spec §4.1）。
/// - 每次写操作都记进本机 `ai_agent_actions`（不同步、不备份），撤销按记录里的
///   撤销载荷调 [OpUndo.revert]——过了会话、重启 app 也能撤。
class AiAgentToolbox implements AgentToolbox, AgentSkillProvider {
  AiAgentToolbox({
    required this.invoker,
    required this.database,
    DateTime Function()? clock,
    this.resident = kAiAgentResidentOps,
    this.taskPollInterval = const Duration(seconds: 3),
    this.maxTaskWatch = const Duration(hours: 6),
    List<AiAgentAppSkill>? skills,
  }) : _clock = clock ?? DateTime.now,
       _skills = skills ?? buildAiAgentSkills();

  final List<AiAgentAppSkill> _skills;

  /// 组合技能（spec §6.3）：所需操作全部当前可用的才给模型。
  @override
  List<AgentSkill> skills() => <AgentSkill>[
    for (final AiAgentAppSkill skill in _skills)
      if (skill.requiredOps.every((String id) => _available(id) != null)) skill,
  ];

  /// 长任务轮询间隔与最长盯多久（spec §6.1）。
  final Duration taskPollInterval;
  final Duration maxTaskWatch;

  /// 长任务结束时通知（控制器据此在对话里报告并自动续一轮）。
  AiAgentTaskFinished? onTaskFinished;

  bool _disposed = false;

  /// 停掉所有在途的长任务轮询。
  void dispose() => _disposed = true;

  final OpInvoker invoker;
  final FushiDatabase database;
  final List<String> resident;
  final DateTime Function() _clock;

  OpCatalog get catalog => invoker.catalog;

  @override
  List<AgentToolSpec> residentTools() => <AgentToolSpec>[
    for (final String id in resident)
      if (_available(id) case final FushiOp op) agentToolSpecOf(op),
  ];

  @override
  List<AgentToolSpec> searchTools(String query, {int limit = 12}) =>
      <AgentToolSpec>[
        for (final FushiOp op in catalog.search(query, limit: limit))
          agentToolSpecOf(op),
      ];

  @override
  AgentToolSpec? describeTool(String name) {
    final FushiOp? op = _available(name);
    return op == null ? null : agentToolSpecOf(op);
  }

  FushiOp? _available(String id) {
    final FushiOp? op = catalog[id];
    if (op == null || !op.currentAvailability().isAvailable) return null;
    return op;
  }

  @override
  Future<AgentToolResult> execute(AgentToolInvocation invocation) async {
    final FushiOp? op = catalog[invocation.name];
    if (op == null) return const AgentToolResult.error('unknown_tool');
    final FushiOpSpec spec = op.spec;
    if (spec.needsConfirmation && !invocation.confirmed) {
      // agent loop 保证不会走到这里；万一走到，绝不替用户表态。
      return const AgentToolResult.error('confirmation_required');
    }
    final Set<String> gates = <String>{
      // 可逆操作：撤销就是兜底，直接注入；强制确认 / 不可逆：只在用户点了同意后注入。
      if (spec.risk != OpRisk.read &&
          (invocation.confirmed || !spec.needsConfirmation))
        for (final OpParam p in spec.gateParams) p.name,
    };
    final OpInvocation result;
    try {
      result = await invoker.invoke(
        invocation.name,
        invocation.arguments,
        caller: OpCaller.model,
        grantedGates: gates,
        captureUndo: op.undo != null,
      );
    } on CtlFailure catch (failure) {
      if (spec.risk != OpRisk.read) {
        await _record(invocation, spec, resultCode: failure.code);
      }
      return AgentToolResult.error(failure.code, failure.message);
    } on Object catch (error) {
      if (spec.risk != OpRisk.read) {
        await _record(invocation, spec, resultCode: 'internal');
      }
      return AgentToolResult.error('internal', '$error');
    }
    final Object? modelData = spec.sensitiveResult
        ? const <String, Object?>{
            'ok': true,
            'note':
                'The result contains a one-time credential; it was shown to the user and withheld from you.',
          }
        : redactAiAgentResult(result.result);
    final String? userPreview = spec.sensitiveResult
        ? _preview(result.result)
        : null;
    if (spec.risk == OpRisk.read) {
      return AgentToolResult.ok(
        modelData,
        taskId: op.taskIdFrom(result.result),
        userPreview: userPreview,
      );
    }
    final int actionId = await _record(
      invocation,
      spec,
      resultCode: 'ok',
      undo: result.undo,
    );
    final String? taskId = op.taskIdFrom(result.result);
    if (spec.longRunning && taskId != null && op.taskStatus != null) {
      unawaited(_watchTask(invocation.sessionId, op, taskId));
    }
    return AgentToolResult.ok(
      modelData,
      actionId: result.undo == null ? null : '$actionId',
      before: result.undo?.before,
      after: result.undo?.after,
      taskId: taskId,
      userPreview: userPreview,
    );
  }

  static String _preview(Object? data) {
    try {
      return const JsonEncoder.withIndent('  ').convert(data);
    } on JsonUnsupportedObjectError {
      return '$data';
    }
  }

  Future<int> _record(
    AgentToolInvocation invocation,
    FushiOpSpec spec, {
    required String resultCode,
    OpUndoRecord? undo,
  }) => database.insertAiAgentAction(
    AiAgentActionsCompanion.insert(
      sessionId: invocation.sessionId,
      opId: invocation.name,
      argsJson: jsonEncode(redactAiAgentArgs(invocation.arguments)),
      risk: spec.risk.name,
      confirmation: invocation.confirmed ? 'user' : 'auto',
      resultCode: resultCode,
      undoPayloadJson: Value<String?>(
        undo == null ? null : jsonEncode(undo.payload),
      ),
      beforeText: Value<String?>(undo?.before),
      afterText: Value<String?>(undo?.after),
      createdAt: _clock().millisecondsSinceEpoch,
    ),
  );

  @override
  Future<AgentUndoResult> undo(String actionId) async {
    final int? id = int.tryParse(actionId);
    final AiAgentActionRow? row = id == null
        ? null
        : await database.getAiAgentAction(id);
    if (row == null || row.undoPayloadJson == null) {
      return const AgentUndoResult(AgentUndoStatus.notUndoable);
    }
    if (row.undoneAt != null) {
      return AgentUndoResult(
        row.undoStatus == 'superseded'
            ? AgentUndoStatus.superseded
            : AgentUndoStatus.done,
      );
    }
    final OpUndo? undo = catalog[row.opId]?.undo;
    if (undo == null) return const AgentUndoResult(AgentUndoStatus.notUndoable);
    final Object? payload = jsonDecode(row.undoPayloadJson!);
    if (payload is! Map) {
      return const AgentUndoResult(AgentUndoStatus.failed, 'bad_payload');
    }
    final OpUndoOutcome outcome;
    try {
      outcome = await undo.revert(Map<String, Object?>.from(payload));
    } on Object catch (error) {
      return AgentUndoResult(AgentUndoStatus.failed, '$error');
    }
    final AgentUndoStatus status = switch (outcome.status) {
      OpUndoStatus.done => AgentUndoStatus.done,
      OpUndoStatus.superseded => AgentUndoStatus.superseded,
      OpUndoStatus.failed => AgentUndoStatus.failed,
    };
    if (status != AgentUndoStatus.failed) {
      await database.markAiAgentActionUndone(
        row.id,
        undoneAt: _clock().millisecondsSinceEpoch,
        status: outcome.status.name,
      );
    }
    return AgentUndoResult(status, outcome.message);
  }

  /// 轮询一个长任务直到结束（或超过 [maxTaskWatch] / 工具箱被释放）。状态路由
  /// 报 404（任务记录已没了）当失败结束；其它错误继续轮询。
  Future<void> _watchTask(String sessionId, FushiOp op, String taskId) async {
    final Future<OpTaskStatus> Function(String taskId) read = op.taskStatus!;
    final DateTime deadline = _clock().add(maxTaskWatch);
    while (!_disposed && _clock().isBefore(deadline)) {
      await Future<void>.delayed(taskPollInterval);
      if (_disposed) return;
      OpTaskStatus status;
      try {
        status = await read(taskId);
      } on CtlFailure catch (failure) {
        if (failure.status != 404) continue;
        status = OpTaskStatus(
          terminal: true,
          summary: failure.message ?? failure.code,
        );
      } on Object {
        continue;
      }
      if (!status.terminal) continue;
      onTaskFinished?.call(sessionId, op.id, taskId, status);
      return;
    }
  }
}

/// 目录操作 → agent 工具描述（表态参数不进 schema）。
AgentToolSpec agentToolSpecOf(FushiOp op) {
  final FushiOpSpec spec = op.spec;
  return AgentToolSpec(
    name: spec.id,
    description: spec.summary,
    parameters: spec.modelSchema(),
    risk: AgentToolRisk.fromName(spec.risk.name),
    confirm: spec.confirm,
    undoable: spec.undoable,
    longRunning: spec.longRunning,
  );
}

/// 抹掉参数里像凭据的值（递归）。
Map<String, Object?> redactAiAgentArgs(Map<String, Object?> args) =>
    <String, Object?>{
      for (final MapEntry<String, Object?> e in args.entries)
        e.key: _kSecretKey.hasMatch(e.key)
            ? '<redacted>'
            : e.value is Map
            ? redactAiAgentArgs(Map<String, Object?>.from(e.value! as Map))
            : e.value,
    };
