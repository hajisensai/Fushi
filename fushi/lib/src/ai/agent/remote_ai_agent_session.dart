/// 「AI 助手」的远端会话（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §6.5）：手机本机没指派提供商、「下载执行设备」指向一台宣告 `agent` 的已配对电脑 /
/// 服务端时，整场会话在那台设备上跑——用它的 AI 指派、它描述的操作、它那边记账与
/// 撤销。手机只长轮询与语言无关的快照、发动作，对话界面不区分本机与远端。
///
/// 断线时在条目里**固定位置**插一条本地提示（`errorCode` =
/// [kAiAgentRemoteUnavailableCode]），并把 running / 待答卡片放开，用户能重试或停止；
/// 恢复后提示留在原处。host 上的会话没了（闲置回收 / host 重启）就不再轮询。
///
/// 会话历史（BUG-4067）：host 宣告了 `agentHistory`（[HostAssistantTarget.supportsAgentHistory]）
/// 时，本对象同时是会话库（[AiAgentSessionLibrary]）——列出 / 续接 / 改名 / 删除这台
/// 设备在 host 上发起的会话，界面与本机会话列表同一套。老 host 没有这一面，
/// [sessionLibrary] 为 null，行为同升级前。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart' show AiAgentSessionSummary;
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/sync/assistant/agent_assistant_host.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';

import 'package:fushi/src/ai/agent/ai_agent_conversation_controller.dart';
import 'package:fushi/src/sync/interconnect_assistant_client.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 本地插入的「连不上执行设备」提示条目的停止码（界面按 i18n 渲染）。
const String kAiAgentRemoteUnavailableCode = 'remote_unavailable';

class RemoteAiAgentSession extends ChangeNotifier
    implements AiAgentConversationController, AiAgentSessionLibrary {
  RemoteAiAgentSession._({
    required InterconnectAssistantClient client,
    required HostAssistantTarget target,
    required String locale,
    required Duration retryDelay,
    required Duration longPollWait,
    required Duration undoTimeout,
  }) : _client = client,
       _target = target,
       _locale = locale,
       _retryDelay = retryDelay,
       _longPollWait = longPollWait,
       _undoTimeout = undoTimeout;

  /// 在 [target] 上开一场会话。失败原样抛 [HostAssistantException]（409 的 detail 是
  /// host 的 reason 短码），由入口翻成引导文案。
  static Future<RemoteAiAgentSession> open({
    required InterconnectAssistantClient client,
    required HostAssistantTarget target,
    required String locale,
    Duration retryDelay = const Duration(seconds: 3),
    Duration longPollWait = InterconnectAssistantClient.longPollWait,
    Duration undoTimeout = const Duration(seconds: 30),
  }) async {
    final RemoteAiAgentSession session = RemoteAiAgentSession._(
      client: client,
      target: target,
      locale: locale,
      retryDelay: retryDelay,
      longPollWait: longPollWait,
      undoTimeout: undoTimeout,
    );
    await session._start();
    return session;
  }

  /// 正在用的远端会话：浮层与整页拿同一个对象（展开 / 收回不丢对话）。入口
  /// （`openAiAgent` / `pushAiAgentPage`）按执行设备复用或换新。
  static RemoteAiAgentSession? active;

  final InterconnectAssistantClient _client;
  final HostAssistantTarget _target;
  final String _locale;
  final Duration _retryDelay;
  final Duration _longPollWait;
  final Duration _undoTimeout;

  String? _id;
  int _revision = 0;
  int _generation = 0;
  Map<String, Object?> _view = const <String, Object?>{};
  List<AgentEntry> _hostEntries = const <AgentEntry>[];

  /// 本地插入的断线提示：(插在 host 条目的第几条之后, 提示)。
  final List<(int, AgentEntry)> _notices = <(int, AgentEntry)>[];
  int _noticeSeq = 0;

  bool _unreachable = false;
  bool _lost = false;
  bool _disposed = false;

  HostAssistantTarget get target => _target;

  /// host 上的会话已经没了：入口据此换一场新的。
  bool get isLost => _lost;

  bool get isDisposed => _disposed;

  /// 还能接着用（入口复用 [active] 的判据）：没释放、host 会话还在、已经开上了。
  bool get isUsable => !_disposed && !_lost && _id != null;

  bool get _offline => _unreachable || _lost;

  @override
  String? get executorLabel => _target.label;

  /// 执行设备宣告了会话历史才有会话库（列的是 host 上这台设备发起的会话）。
  @override
  AiAgentSessionLibrary? get sessionLibrary =>
      _target.supportsAgentHistory ? this : null;

  @override
  String? get storedOn => _target.label;

  final ValueNotifier<int> _sessionsRevision = ValueNotifier<int>(0);

  @override
  ValueListenable<int> get sessionsRevision => _sessionsRevision;

  /// host 上这一场的会话 id（快照 `id`）；还没开上时为 null。
  @override
  String? get currentSessionId {
    final Object? id = _view['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  /// 还没说过话：host 不落库空会话，列表里单独画一行「新对话」。
  @override
  bool get currentSessionUnsaved => _hostEntries.isEmpty;

  void _bumpSessions() {
    if (!_disposed) _sessionsRevision.value++;
  }

  @override
  Future<List<AiAgentSessionSummary>> listSessions() =>
      _client.listHistory(_target, feature: kHostAssistantFeatureAgent);

  /// 续接 host 上的一场存档会话：先在 host 上开成活的，开上了再关掉手上这场
  /// （续接失败时手上这场不动）。跑着时不切（与本机同一判据）。
  @override
  Future<bool> switchToSession(String sessionId) async {
    if (_disposed) return false;
    if (sessionId == currentSessionId) return true;
    if (running) return false;
    final HostAssistantEnvelope envelope;
    try {
      envelope = await _client.open(
        _target,
        feature: kHostAssistantFeatureAgent,
        locale: _locale,
        resume: sessionId,
      );
    } on Object catch (error) {
      ErrorLogService.instance.logDiagnostic(
        'RemoteAiAgent.resume',
        '${_target.label}: $error',
      );
      return false;
    }
    if (_disposed) {
      unawaited(_closeHost(envelope.id));
      return false;
    }
    final String? old = _id;
    final bool wasLost = _lost;
    _resetState();
    _id = envelope.id;
    _apply(envelope, force: true);
    unawaited(_pollLoop(_generation));
    if (old != null && !wasLost) await _closeHost(old);
    _bumpSessions();
    return true;
  }

  @override
  Future<void> renameSession(String sessionId, String title) async {
    final String trimmed = title.trim();
    if (trimmed.isEmpty) return;
    try {
      await _client.renameHistory(
        _target,
        sessionId,
        feature: kHostAssistantFeatureAgent,
        title: trimmed,
      );
    } on Object catch (error) {
      _logHistoryError('rename', error);
    }
    _bumpSessions();
  }

  /// 删的是手上这场：先换成一场新对话（等 host 把旧的关掉收尾），再删存档——不然
  /// 关闭时的收尾存档可能晚于删除把它写回来。
  @override
  Future<bool> deleteSession(String sessionId) async {
    if (sessionId == currentSessionId) await _reopen(awaitClose: true);
    try {
      await _client.deleteHistory(
        _target,
        sessionId,
        feature: kHostAssistantFeatureAgent,
      );
      return true;
    } on Object catch (error) {
      _logHistoryError('delete', error);
      return false;
    } finally {
      _bumpSessions();
    }
  }

  void _logHistoryError(String what, Object error) => ErrorLogService.instance
      .logDiagnostic('RemoteAiAgent.$what', '${_target.label}: $error');

  @override
  List<AgentEntry> get entries {
    if (_notices.isEmpty) return _hostEntries;
    final List<AgentEntry> merged = List<AgentEntry>.of(_hostEntries);
    for (final (int at, AgentEntry notice) in _notices.reversed) {
      merged.insert(at.clamp(0, merged.length), notice);
    }
    return merged;
  }

  @override
  bool get running => !_offline && _view['running'] == true;

  @override
  int get undoableCount => (_view['undoable'] as num?)?.toInt() ?? 0;

  @override
  int get totalTokens => (_view['tokens'] as num?)?.toInt() ?? 0;

  @override
  AiChatUsage get usage => _view['usage'] is Map
      ? AiChatUsage.fromJson(Map<String, Object?>.from(_view['usage'] as Map))
      : const AiChatUsage();

  @override
  Map<String, double> get cost => agentCostFromJson(_view['cost']);

  String? get _pendingKind {
    if (_offline) return null;
    final Object? pending = _view['pending'];
    return pending is Map ? '${pending['kind']}' : null;
  }

  @override
  bool get awaitingConfirm => _pendingKind == kAgentPendingConfirm;

  @override
  bool get awaitingChoice => _pendingKind == kAgentPendingChoice;

  @override
  void answerConfirm(bool approved) => unawaited(
    _act(<String, Object?>{'type': 'answerConfirm', 'approve': approved}),
  );

  @override
  void answerChoice(String? id) =>
      unawaited(_act(<String, Object?>{'type': 'answerChoice', 'choice': id}));

  /// 截图不过线：远端用的是那台设备配的模型，本机不知道它能不能收图。
  @override
  bool get acceptsImages => false;

  @override
  Future<void> send(
    String text, {
    AgentUiContext? context,
    List<AiChatImage> images = const <AiChatImage>[],
  }) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return Future<void>.value();
    return _act(<String, Object?>{
      'type': 'text',
      'text': trimmed,
      if (context != null) 'context': context.toJson(),
    });
  }

  @override
  void cancel() => unawaited(_act(const <String, Object?>{'type': 'cancel'}));

  @override
  Future<AgentUndoResult> undoEntry(String entryId) async {
    final List<AgentUndoResult> results = await _undo(<String, Object?>{
      'type': 'undo',
      'entryId': entryId,
    });
    return results.isEmpty
        ? const AgentUndoResult(AgentUndoStatus.failed, 'no_result')
        : results.first;
  }

  @override
  Future<List<AgentUndoResult>> undoAll() =>
      _undo(const <String, Object?>{'type': 'undoAll'});

  /// 撤销在 host 后台跑：发动作后等快照里的 `lastUndo.seq` 越过发之前的值。
  Future<List<AgentUndoResult>> _undo(Map<String, Object?> action) async {
    final int before = _undoSeq;
    final int generation = _generation;
    await _act(action);
    if (_offline || generation != _generation) {
      return const <AgentUndoResult>[
        AgentUndoResult(AgentUndoStatus.failed, 'remote_unavailable'),
      ];
    }
    if (_undoSeq <= before) {
      final Completer<void> done = Completer<void>();
      void check() {
        if ((_undoSeq > before || _offline || generation != _generation) &&
            !done.isCompleted) {
          done.complete();
        }
      }

      addListener(check);
      try {
        await done.future.timeout(_undoTimeout);
      } on TimeoutException {
        return const <AgentUndoResult>[
          AgentUndoResult(AgentUndoStatus.failed, 'timeout'),
        ];
      } finally {
        removeListener(check);
      }
      if (_undoSeq <= before) {
        return const <AgentUndoResult>[
          AgentUndoResult(AgentUndoStatus.failed, 'remote_unavailable'),
        ];
      }
    }
    final Object? lastUndo = _view['lastUndo'];
    final Object? results = lastUndo is Map ? lastUndo['results'] : null;
    return <AgentUndoResult>[
      if (results is List)
        for (final Object? r in results)
          if (r is Map)
            AgentUndoResult(
              AgentUndoStatus.values.firstWhere(
                (AgentUndoStatus s) => s.name == r['status'],
                orElse: () => AgentUndoStatus.failed,
              ),
              r['message'] as String?,
            ),
    ];
  }

  int get _undoSeq {
    final Object? lastUndo = _view['lastUndo'];
    return lastUndo is Map ? (lastUndo['seq'] as num?)?.toInt() ?? 0 : 0;
  }

  /// 开一场新对话：关掉 host 上的旧会话，在同一台设备上再开一场。
  @override
  Future<void> newSession() => _reopen();

  /// 丢掉手上这一场的本地状态（换场 / 新对话之前）。
  void _resetState() {
    _generation++;
    _id = null;
    _revision = 0;
    _view = const <String, Object?>{};
    _hostEntries = const <AgentEntry>[];
    _notices.clear();
    _unreachable = false;
    _lost = false;
  }

  Future<void> _reopen({bool awaitClose = false}) async {
    if (_disposed) return;
    final String? old = _id;
    final bool wasLost = _lost;
    _resetState();
    notifyListeners();
    _bumpSessions();
    if (old != null && !wasLost) {
      if (awaitClose) {
        await _closeHost(old);
      } else {
        unawaited(_closeHost(old));
      }
    }
    try {
      await _start();
    } on Object catch (error) {
      _onError(error, 'reopen');
    }
  }

  Future<void> _start() async {
    final HostAssistantEnvelope first = await _client.open(
      _target,
      feature: kHostAssistantFeatureAgent,
      locale: _locale,
    );
    if (_disposed) {
      unawaited(_closeHost(first.id));
      return;
    }
    _id = first.id;
    _apply(first, force: true);
    unawaited(_pollLoop(_generation));
  }

  Future<void> _act(Map<String, Object?> action) async {
    if (_disposed) return;
    final String? id = _id;
    if (_lost || id == null) {
      _markUnavailable();
      return;
    }
    try {
      _apply(await _client.act(_target, id, action));
    } on Object catch (error) {
      _onError(error, 'act');
    }
  }

  Future<void> _pollLoop(int generation) async {
    while (!_disposed && !_lost && generation == _generation) {
      final String? id = _id;
      if (id == null) return;
      try {
        final HostAssistantEnvelope envelope = await _client.read(
          _target,
          id,
          after: _revision,
          wait: _longPollWait,
        );
        if (generation != _generation) return;
        _apply(envelope);
      } on Object catch (error) {
        if (generation != _generation) return;
        _onError(error, 'poll');
        if (_disposed || _lost) return;
        await Future<void>.delayed(_retryDelay);
      }
    }
  }

  void _apply(HostAssistantEnvelope envelope, {bool force = false}) {
    if (_disposed || envelope.id != _id) return;
    final bool recovered = _unreachable;
    _unreachable = false;
    if (!force && envelope.revision <= _revision && !recovered) return;
    // 一轮跑完 / 第一次落库：host 那边的存档变了，会话列表重读。
    final bool settled =
        (_view['running'] == true && envelope.view['running'] != true) ||
        (_hostEntries.isEmpty &&
            (envelope.view['entries'] as List? ?? const <Object?>[])
                .isNotEmpty);
    _revision = envelope.revision;
    _view = envelope.view;
    _hostEntries = <AgentEntry>[
      for (final Object? raw
          in (_view['entries'] as List? ?? const <Object?>[]))
        if (raw is Map) _liveEntry(Map<String, Object?>.from(raw)),
    ];
    notifyListeners();
    if (settled) _bumpSessions();
  }

  /// 这里是活的快照：不按存档的中断规则收尾，状态与错误码原样还原。
  static AgentEntry _liveEntry(Map<String, Object?> json) =>
      AgentEntry.fromJson(json, settleInterrupted: false);

  void _onError(Object error, String where) {
    if (_disposed) return;
    ErrorLogService.instance.logDiagnostic(
      'RemoteAiAgent.$where',
      '${_target.label}: $error',
    );
    if (error is HostAssistantException && error.sessionGone) _lost = true;
    _markUnavailable();
  }

  void _markUnavailable() {
    if (_unreachable) {
      notifyListeners();
      return;
    }
    _unreachable = true;
    _notices.add((
      _hostEntries.length,
      AgentEntry(
        id: 'remote-notice-${++_noticeSeq}',
        kind: AgentEntryKind.notice,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        errorCode: kAiAgentRemoteUnavailableCode,
      ),
    ));
    notifyListeners();
  }

  Future<void> _closeHost(String id) async {
    try {
      await _client.close(_target, id);
    } on Object catch (error) {
      ErrorLogService.instance.logDiagnostic(
        'RemoteAiAgent.close',
        '${_target.label}: $error',
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(active, this)) active = null;
    final String? id = _id;
    // 退出即关 host 上的会话（待答卡片在 host 上按拒绝收尾）；失败只记诊断，
    // host 闲置回收兜底。
    if (id != null && !_lost) unawaited(_closeHost(id));
    _sessionsRevision.dispose();
    super.dispose();
  }
}
