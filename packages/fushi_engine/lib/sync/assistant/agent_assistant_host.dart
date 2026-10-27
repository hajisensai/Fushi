/// 互联 host 的「AI 助手」会话（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §6.5）：手机没配 AI 时，整场 agent 会话交给已配对的电脑 / 服务端跑——用 host
/// **自己的** AI 指派、host 自己描述的操作目录，写操作的记账与撤销也落在 host 上。
///
/// 手机只收与语言无关的快照、只发动作：
///
/// ```
/// 快照  {entries: [AgentEntry.toJson…], running, tokens, undoable,
///        pending?: {kind: confirm|choice, entryId}, tools?: {source, count},
///        lastUndo?: {seq, results: [{entryId?, status, message?}]}}
/// 动作  {type: text, text, context?}
///       {type: answerConfirm, approve}
///       {type: answerChoice, choice?}
///       {type: undo, entryId}
///       {type: undoAll}
///       {type: cancel}
/// ```
///
/// 条目里没有 UI 文案（停止原因是短码、工具名是目录 id），手机按自己的语言渲染。
/// 确认卡片与候选卡片由一个 Completer 型 [AgentHost] 等手机作答；会话关闭 / 取消时
/// 一律按「拒绝 / 取消」收尾，**绝不替用户同意**。
///
/// 另有 [CompositeHostAssistantProvider]：把多个 provider（AI 下视频、AI 助手…）按
/// feature 合成一个，让一台 host 同时宣告多种会话。
library;

import 'dart:async';
import 'dart:math';

import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/assistant/video_acquisition_assistant_host.dart'
    show kHostAssistantReasonDisabled;

/// 能力位里 AI 助手工具集的键：`{source, count}`。`source` = 谁描述的操作
/// （`app` / `server`），`count` = 当前可用的操作数（不含元工具）。
const String kHostAssistantAgentToolsKey = 'agentTools';

/// 能力位里按 feature 给的不可用短码：`{feature: reason}`。一台 host 可以 AI 下视频
/// 能开、AI 助手没指派提供商——顶层 `reason` 只在全部开不了时才有，客户端靠它分辨。
const String kHostAssistantReasonsKey = 'reasons';

/// 快照里待答卡片的种类。
const String kAgentPendingConfirm = 'confirm';
const String kAgentPendingChoice = 'choice';

/// 开一场 host 执行的 agent 会话要的零件：模型、工具箱、会话建好后接什么、会话
/// 结束时释放什么。
class AgentSessionParts {
  const AgentSessionParts({
    required this.llm,
    required this.toolbox,
    this.attach,
    this.release,
  });

  final AgentLlm llm;
  final AgentToolbox toolbox;

  /// 会话对象建好后调用一次（如把工具箱的长任务结束回调接到
  /// `AgentSession.continueAfterTask`）。
  final void Function(AgentSession session)? attach;

  /// 会话关闭时调用（释放模型客户端、停任务轮询…）。
  final void Function()? release;
}

/// 按客户端语言开会话的零件（host 现取指派与工具箱）。
typedef AgentSessionOpener = Future<AgentSessionParts> Function(String locale);

/// 把一场 host 会话的快照存档（host 自己的「AI 操作记录」页能看到远端会话做过的
/// 事、过了会话也能撤销）。可空：服务端没有对话存档页。
typedef AgentSessionPersister = Future<void> Function(AgentSession session);

/// 远端 AI 助手的 provider：能力 / 前置短码 + 开 [AgentAssistantHostSession]。
class AgentAssistantHost implements HostAssistantProvider {
  AgentAssistantHost({
    required Future<String?> Function() blocker,
    required AgentSessionOpener open,
    required String source,
    int Function()? toolCount,
    AgentSessionPersister? persist,
    AgentLimits limits = const AgentLimits(),
    DateTime Function()? clock,
    String Function()? newSessionId,
  }) : _blocker = blocker,
       _open = open,
       _source = source,
       _toolCount = toolCount,
       _persist = persist,
       _limits = limits,
       _clock = clock ?? DateTime.now,
       _newSessionId = newSessionId;

  /// null = 现在就能开；否则是缺什么（`no_provider` / `not_ready` / `disabled`）。
  final Future<String?> Function() _blocker;
  final AgentSessionOpener _open;
  final String _source;
  final int Function()? _toolCount;
  final AgentSessionPersister? _persist;
  final AgentLimits _limits;
  final DateTime Function() _clock;
  final String Function()? _newSessionId;

  @override
  Future<Map<String, Object?>> capability() async {
    final String? reason = await _blocker();
    int? count;
    if (reason == null) {
      try {
        count = _toolCount?.call();
      } on Object catch (error, stack) {
        engineLog.log('AgentAssistantHost.toolCount', error, stack);
      }
    }
    return <String, Object?>{
      'supported': reason == null,
      'features': <String>[if (reason == null) kHostAssistantFeatureAgent],
      if (reason != null) 'reason': reason,
      if (reason == null)
        kHostAssistantAgentToolsKey: <String, Object?>{
          'source': _source,
          'count': ?count,
        },
    };
  }

  @override
  Future<HostAssistantSession> open(
    String feature, {
    required String locale,
  }) async {
    if (feature != kHostAssistantFeatureAgent) {
      throw ArgumentError.value(
        feature,
        'feature',
        'unknown assistant feature',
      );
    }
    final String? reason = await _blocker();
    if (reason != null) throw HostAssistantUnavailable(reason);
    final AgentSessionParts parts = await _open(locale);
    final AgentCompleterHost host = AgentCompleterHost();
    final AgentSession session = AgentSession(
      id: (_newSessionId ?? _defaultSessionId)(),
      llm: parts.llm,
      toolbox: parts.toolbox,
      host: host,
      limits: _limits,
      clock: _clock,
    );
    parts.attach?.call(session);
    int? count;
    try {
      count = _toolCount?.call();
    } on Object catch (error, stack) {
      engineLog.log('AgentAssistantHost.toolCount', error, stack);
    }
    return AgentAssistantHostSession(
      session,
      host: host,
      tools: <String, Object?>{'source': _source, 'count': ?count},
      persist: _persist,
      onClose: parts.release,
    );
  }

  String _defaultSessionId() {
    final Random random = Random.secure();
    final String suffix = List<String>.generate(
      6,
      (_) => random.nextInt(36).toRadixString(36),
    ).join();
    // `rm` 前缀：操作记录里一眼看出是远端发起的会话。
    return 'rm${_clock().millisecondsSinceEpoch.toRadixString(36)}$suffix';
  }
}

/// 确认 / 候选由客户端动作作答的 [AgentHost]。同一时刻最多一张待答卡片（loop 串行）。
class AgentCompleterHost implements AgentHost {
  AgentCompleterHost({this.onChanged});

  /// 待答状态变化（开始等 / 已作答）时调用：会话据此推一版新快照。
  void Function()? onChanged;

  Completer<bool>? _confirm;
  Completer<String?>? _choice;
  Set<String> _choiceIds = const <String>{};
  bool _closed = false;

  bool get awaitingConfirm => _confirm != null;
  bool get awaitingChoice => _choice != null;

  @override
  Future<bool> confirm(AgentConfirmRequest request) {
    // 已关闭的会话不再开新卡片：直接按拒绝（不替用户同意）。
    if (_closed) return Future<bool>.value(false);
    final Completer<bool> completer = Completer<bool>();
    _confirm = completer;
    onChanged?.call();
    return completer.future;
  }

  @override
  Future<String?> askChoice(String prompt, List<AgentChoiceOption> options) {
    if (_closed) return Future<String?>.value();
    final Completer<String?> completer = Completer<String?>();
    _choice = completer;
    _choiceIds = <String>{for (final AgentChoiceOption o in options) o.id};
    onChanged?.call();
    return completer.future;
  }

  /// 作答确认卡片；没有待答的确认卡片返回 false（动作晚到，原样忽略）。
  bool answerConfirm(bool approved) {
    final Completer<bool>? completer = _confirm;
    if (completer == null) return false;
    _confirm = null;
    if (!completer.isCompleted) completer.complete(approved);
    onChanged?.call();
    return true;
  }

  /// 作答候选卡片（null = 都不是）；选了不在候选里的 id 抛 [ArgumentError]。
  bool answerChoice(String? id) {
    final Completer<String?>? completer = _choice;
    if (completer == null) return false;
    if (id != null && !_choiceIds.contains(id)) {
      throw ArgumentError.value(id, 'choice', 'not one of the options');
    }
    _choice = null;
    _choiceIds = const <String>{};
    if (!completer.isCompleted) completer.complete(id);
    onChanged?.call();
    return true;
  }

  /// 取消 / 关闭：待答卡片一律按「拒绝 / 取消」收尾。
  void cancelPending() {
    final Completer<bool>? confirm = _confirm;
    final Completer<String?>? choice = _choice;
    _confirm = null;
    _choice = null;
    _choiceIds = const <String>{};
    if (confirm != null && !confirm.isCompleted) confirm.complete(false);
    if (choice != null && !choice.isCompleted) choice.complete(null);
    if (confirm != null || choice != null) onChanged?.call();
  }

  /// 会话关闭：收尾待答卡片，之后的卡片一律直接拒绝。
  void close() {
    _closed = true;
    cancelPending();
  }
}

/// 把一个 host 上的 [AgentSession] 暴露成互联会话。
class AgentAssistantHostSession implements HostAssistantSession {
  AgentAssistantHostSession(
    this._session, {
    required AgentCompleterHost host,
    Map<String, Object?>? tools,
    AgentSessionPersister? persist,
    void Function()? onClose,
  }) : _host = host,
       _tools = tools,
       _persist = persist,
       _onClose = onClose {
    _host.onChanged = _bump;
    _subscription = _session.changes.listen((_) => _bump());
  }

  final AgentSession _session;
  final AgentCompleterHost _host;
  final Map<String, Object?>? _tools;
  final AgentSessionPersister? _persist;
  final void Function()? _onClose;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  late final StreamSubscription<void> _subscription;
  int _revision = 0;
  int _undoSeq = 0;
  List<Map<String, Object?>>? _lastUndo;
  bool _closed = false;

  /// 包着的会话（测试 / 装配用）。
  AgentSession get session => _session;

  @override
  int get revision => _revision;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Map<String, Object?> snapshot() {
    final String? pendingKind = _host.awaitingConfirm
        ? kAgentPendingConfirm
        : _host.awaitingChoice
        ? kAgentPendingChoice
        : null;
    final String? pendingEntry = pendingKind == null
        ? null
        : _lastPendingEntry(
            pendingKind == kAgentPendingConfirm
                ? AgentEntryKind.confirm
                : AgentEntryKind.choice,
          );
    return <String, Object?>{
      'id': _session.id,
      'entries': <Object?>[
        for (final AgentEntry entry in _session.entries) entry.toJson(),
      ],
      'running': _session.running,
      'tokens': _session.totalTokens,
      'usage': _session.usage.toJson(),
      if (_session.cost.isNotEmpty) 'cost': _session.cost,
      'undoable': _session.undoableCount,
      if (pendingKind != null && pendingEntry != null)
        'pending': <String, Object?>{
          'kind': pendingKind,
          'entryId': pendingEntry,
        },
      'tools': ?_tools,
      if (_lastUndo != null)
        'lastUndo': <String, Object?>{'seq': _undoSeq, 'results': _lastUndo},
    };
  }

  String? _lastPendingEntry(AgentEntryKind kind) {
    final List<AgentEntry> entries = _session.entries;
    for (int i = entries.length - 1; i >= 0; i--) {
      final AgentEntry entry = entries[i];
      if (entry.kind == kind) {
        return entry.status == AgentEntryStatus.pending ? entry.id : null;
      }
    }
    return null;
  }

  /// 只校验形状（400）；「此刻能不能点」按会话状态判断，不合时宜的动作原样忽略
  /// （与本机页面同一口径：跑着时再说一句、没有待答卡片时点确认）。对话一轮与
  /// 撤销在后台跑，不等它结束——撤销结果随后经 `lastUndo` 推给客户端。
  @override
  Future<void> act(Map<String, Object?> action) async {
    if (_closed) throw StateError('session closed');
    switch (action['type']) {
      case 'text':
        final Object? text = action['text'];
        if (text is! String || text.trim().isEmpty) {
          throw ArgumentError('text action needs non-empty text');
        }
        final Object? rawContext = action['context'];
        if (rawContext != null && rawContext is! Map) {
          throw ArgumentError('context must be an object');
        }
        final AgentUiContext? context = rawContext is Map
            ? AgentUiContext.fromJson(Map<String, Object?>.from(rawContext))
            : null;
        if (_session.running) return;
        unawaited(
          _runGuarded('send', () => _session.send(text, context: context)),
        );
      case 'answerConfirm':
        final Object? approve = action['approve'];
        if (approve is! bool) {
          throw ArgumentError('answerConfirm needs a bool approve');
        }
        _host.answerConfirm(approve);
      case 'answerChoice':
        final Object? choice = action['choice'];
        if (choice != null && (choice is! String || choice.isEmpty)) {
          throw ArgumentError('choice must be a non-empty string or null');
        }
        _host.answerChoice(choice as String?);
      case 'undo':
        final Object? entryId = action['entryId'];
        if (entryId is! String || entryId.isEmpty) {
          throw ArgumentError('undo needs an entryId');
        }
        unawaited(
          _runGuarded('undo', () async {
            final AgentUndoResult result = await _session.undoEntry(entryId);
            _recordUndo(<Map<String, Object?>>[
              _undoJson(result, entryId: entryId),
            ]);
          }),
        );
      case 'undoAll':
        unawaited(
          _runGuarded('undoAll', () async {
            final List<AgentUndoResult> results = await _session.undoAll();
            _recordUndo(<Map<String, Object?>>[
              for (final AgentUndoResult r in results) _undoJson(r),
            ]);
          }),
        );
      case 'cancel':
        // 先置取消标志再收尾待答卡片：被拒的卡片返回后 loop 直接停，不再发请求。
        _session.cancel();
        _host.cancelPending();
      default:
        throw ArgumentError('unknown action type: ${action['type']}');
    }
  }

  Future<void> _runGuarded(String what, Future<void> Function() run) async {
    try {
      await run();
    } on Object catch (error, stack) {
      engineLog.log('AgentAssistantHostSession.$what', error, stack);
    } finally {
      if (!_closed) await _save();
    }
  }

  Future<void> _save() async {
    final AgentSessionPersister? persist = _persist;
    if (persist == null || _session.entries.isEmpty) return;
    try {
      await persist(_session);
    } on Object catch (error, stack) {
      engineLog.log('AgentAssistantHostSession.persist', error, stack);
    }
  }

  static Map<String, Object?> _undoJson(
    AgentUndoResult result, {
    String? entryId,
  }) => <String, Object?>{
    'entryId': ?entryId,
    'status': result.status.name,
    'message': ?result.message,
  };

  void _recordUndo(List<Map<String, Object?>> results) {
    _undoSeq++;
    _lastUndo = results;
    _bump();
  }

  void _bump() {
    _revision++;
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // 顺序同 cancel：先停 loop，再按拒绝收尾待答卡片（绝不替用户同意）。
    _session.cancel();
    _host.close();
    await _subscription.cancel();
    await _save();
    _session.dispose();
    _onClose?.call();
    await _changes.close();
  }
}

/// 把多个 provider 按 feature 合成一个：能力位合并 features、按 feature 分派 open。
///
/// - `features` = 各 provider 当前能开的 feature 并集（按 [byFeature] 的顺序）；
/// - `supported` = 至少有一个能开；
/// - `reasons` = 每个开不了的 feature 的短码；顶层 `reason` 只在全部开不了时才给
///   （取 [byFeature] 里第一个 feature 的短码——老客户端只认它，第一个放 AI 下视频）；
/// - 其余字段（如 [kHostAssistantAgentToolsKey]）原样并入。
class CompositeHostAssistantProvider implements HostAssistantProvider {
  CompositeHostAssistantProvider(Map<String, HostAssistantProvider> byFeature)
    : _byFeature = Map<String, HostAssistantProvider>.unmodifiable(byFeature);

  final Map<String, HostAssistantProvider> _byFeature;

  @override
  Future<Map<String, Object?>> capability() async {
    final Map<HostAssistantProvider, Map<String, Object?>> answers =
        <HostAssistantProvider, Map<String, Object?>>{};
    for (final HostAssistantProvider provider in _byFeature.values) {
      if (answers.containsKey(provider)) continue;
      try {
        answers[provider] = await provider.capability();
      } on Object catch (error, stack) {
        engineLog.log(
          'CompositeHostAssistantProvider.capability',
          error,
          stack,
        );
        answers[provider] = const <String, Object?>{
          'supported': false,
          'features': <String>[],
          'reason': kHostAssistantReasonDisabled,
        };
      }
    }
    final List<String> features = <String>[];
    final Map<String, String> reasons = <String, String>{};
    final Map<String, Object?> extra = <String, Object?>{};
    for (final MapEntry<String, HostAssistantProvider> e
        in _byFeature.entries) {
      final Map<String, Object?> answer = answers[e.value]!;
      final Object? offered = answer['features'];
      final bool open =
          answer['supported'] == true &&
          offered is List &&
          offered.contains(e.key);
      if (open) {
        features.add(e.key);
      } else {
        reasons[e.key] = '${answer['reason'] ?? kHostAssistantReasonDisabled}';
      }
    }
    for (final Map<String, Object?> answer in answers.values) {
      for (final MapEntry<String, Object?> field in answer.entries) {
        if (const <String>{
          'supported',
          'features',
          'reason',
          kHostAssistantReasonsKey,
        }.contains(field.key)) {
          continue;
        }
        extra[field.key] = field.value;
      }
    }
    return <String, Object?>{
      ...extra,
      'supported': features.isNotEmpty,
      'features': features,
      if (features.isEmpty && _byFeature.isNotEmpty)
        'reason':
            reasons[_byFeature.keys.first] ?? kHostAssistantReasonDisabled,
      if (reasons.isNotEmpty) kHostAssistantReasonsKey: reasons,
    };
  }

  @override
  Future<HostAssistantSession> open(String feature, {required String locale}) {
    final HostAssistantProvider? provider = _byFeature[feature];
    if (provider == null) {
      throw ArgumentError.value(
        feature,
        'feature',
        'unknown assistant feature',
      );
    }
    return provider.open(feature, locale: locale);
  }
}
