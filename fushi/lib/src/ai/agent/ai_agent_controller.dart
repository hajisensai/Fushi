import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';

import 'package:fushi/src/ai/agent/ai_agent_conversation_controller.dart';
import 'package:fushi/src/ai/agent/ai_agent_in_process_ops.dart';
import 'package:fushi/src/ai/agent/ai_agent_session_archive.dart';
import 'package:fushi/src/ai/agent/ai_agent_toolbox.dart';
import 'package:fushi/src/ops/app_op_context.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';

/// 对话存档与操作记录保留多久（spec D3 / D5）。
const Duration kAiAgentHistoryRetention = Duration(days: 30);

/// 「AI 助手」当前可用的提供商；null = 未指派（不发任何请求，引导去设置）。
AiProviderConfig? resolveAiAgentProvider(AiSettingsSource settings) => settings
    .aiFeatureAssignments
    .resolve(AiFeature.agent, settings.aiProviders);

/// AI 页 / 浮层 / 终端共用的界面回调：确认卡片与候选卡片由用户在条目上点。
///
/// [AgentSession] 先把 pending 条目放进对话再调 [confirm] / [askChoice]，这里
/// 只挂一个 Completer，等界面调 [answerConfirm] / [answerChoice] 完成它。同一时刻
/// 最多一张待答卡片（loop 是串行的）。
class AiAgentUiHost implements AgentHost {
  Completer<bool>? _confirm;
  Completer<String?>? _choice;
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  bool get awaitingConfirm => _confirm != null;
  bool get awaitingChoice => _choice != null;

  @override
  Future<bool> confirm(AgentConfirmRequest request) {
    final Completer<bool> completer = Completer<bool>();
    _confirm = completer;
    pending.value++;
    return completer.future;
  }

  @override
  Future<String?> askChoice(String prompt, List<AgentChoiceOption> options) {
    final Completer<String?> completer = Completer<String?>();
    _choice = completer;
    pending.value++;
    return completer.future;
  }

  void answerConfirm(bool approved) {
    final Completer<bool>? completer = _confirm;
    _confirm = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(approved);
    }
    pending.value++;
  }

  void answerChoice(String? id) {
    final Completer<String?>? completer = _choice;
    _choice = null;
    if (completer != null && !completer.isCompleted) completer.complete(id);
    pending.value++;
  }

  /// 会话被关掉 / 取消：待答卡片一律按「拒绝 / 取消」收尾，不替用户同意。
  void cancelPending() {
    answerConfirm(false);
    answerChoice(null);
  }
}

/// 一场进行中的 AI 助手对话 + 它的存档。整页与浮层拿同一个对象，展开 / 收回
/// 都不丢对话（spec §6.4）。
///
/// 同时是本机的会话库（[AiAgentSessionLibrary]）：随时新建 / 切换 / 续接存档会话、
/// 重命名、删除。存档每轮对话后整场重存；标题与所属 Profile 首次落库时定下，之后
/// 不随重存改写（[FushiDatabase.saveAiAgentSessionSnapshot]）。
class AiAgentController extends ChangeNotifier
    implements AiAgentConversationController, AiAgentSessionLibrary {
  AiAgentController._({
    required this.database,
    required this.settings,
    required OpContext opContext,
    AgentLlm Function(AiProviderConfig provider)? llmFactory,
    DateTime Function()? clock,
  }) : _opContext = opContext,
       _llmFactory = llmFactory,
       _clock = clock ?? DateTime.now {
    // 待答卡片的变化也通知监听者（[AiAgentConversationController] 的约定）。
    host.pending.addListener(notifyListeners);
  }

  /// app 内唯一实例（需要 [appOpContext] 已登记）。
  static AiAgentController? _instance;

  static AiAgentController? get instanceOrNull {
    final OpContext? context = appOpContext;
    if (context == null) return null;
    return _instance ??= AiAgentController._(
      database: context.appModel.database,
      settings: context.appModel.prefsRepo,
      opContext: context,
    );
  }

  /// 不挂界面的独立会话（`fushi_cli ai ask`）：自带一个 [host]，确认 / 候选由终端
  /// 经控制通道作答；与 app 内的 AI 浮层互不干扰。
  static AiAgentController headless(OpContext context) => AiAgentController._(
    database: context.appModel.database,
    settings: context.appModel.prefsRepo,
    opContext: context,
  );

  @visibleForTesting
  static AiAgentController forTesting({
    required FushiDatabase database,
    required AiSettingsSource settings,
    required OpContext opContext,
    required AgentLlm Function(AiProviderConfig provider) llmFactory,
    OpInvoker? invoker,
    DateTime Function()? clock,
  }) => AiAgentController._(
    database: database,
    settings: settings,
    opContext: opContext,
    llmFactory: llmFactory,
    clock: clock,
  ).._invoker = invoker;

  final FushiDatabase database;
  final AiSettingsSource settings;
  final OpContext _opContext;
  final AgentLlm Function(AiProviderConfig provider)? _llmFactory;
  final DateTime Function() _clock;
  final AiAgentUiHost host = AiAgentUiHost();

  OpInvoker? _invoker;
  AiAgentToolbox? _toolbox;
  AgentSession? _session;
  AiChatClient? _client;
  StreamSubscription<void>? _changes;
  String _scene = 'general';
  bool _pruned = false;

  /// 当前这场所属 Profile 的 uid：续接存档时取存档的，新会话在第一句话前按激活
  /// Profile 解析。null = 还没解析（新会话尚未说话）。
  String? _sessionProfileUid;

  /// 删掉的会话 id：在途一轮结束时的收尾存档不能把它写回来。
  final Set<String> _deletedSessionIds = <String>{};

  final ValueNotifier<int> _sessionsRevision = ValueNotifier<int>(0);
  bool _disposed = false;

  AgentSession? get session => _session;

  bool get hasProvider => resolveAiAgentProvider(settings) != null;

  @override
  bool get acceptsImages =>
      resolveAiAgentProvider(settings)?.acceptsImages ?? false;

  @override
  bool get running => _session?.running ?? false;

  @override
  List<AgentEntry> get entries => _session?.entries ?? const <AgentEntry>[];

  @override
  int get undoableCount => _session?.undoableCount ?? 0;

  @override
  int get totalTokens => _session?.totalTokens ?? 0;

  @override
  AiChatUsage get usage => _session?.usage ?? const AiChatUsage();

  @override
  Map<String, double> get cost => _session?.cost ?? const <String, double>{};

  @override
  bool get awaitingConfirm => host.awaitingConfirm;

  @override
  bool get awaitingChoice => host.awaitingChoice;

  @override
  void answerConfirm(bool approved) => host.answerConfirm(approved);

  @override
  void answerChoice(String? id) => host.answerChoice(id);

  /// 本机执行。
  @override
  String? get executorLabel => null;

  @override
  AiAgentSessionLibrary get sessionLibrary => this;

  @override
  String? get currentSessionId => _session?.id;

  @override
  bool get currentSessionUnsaved => _session?.entries.isEmpty ?? true;

  @override
  ValueListenable<int> get sessionsRevision => _sessionsRevision;

  AiAgentToolbox get toolbox => _toolbox ??= AiAgentToolbox(
    invoker: _invoker ??= buildInProcessOpInvoker(
      _opContext,
      extra: buildAiAgentInProcessOps(_opContext),
    ),
    database: database,
    clock: _clock,
  )..onTaskFinished = _onTaskFinished;

  /// 长任务结束（spec §6.1）：还是当前这场对话就报告并自动续一轮；对话已换掉的
  /// 只在操作记录里留着（下次恢复那场对话时条目仍显示为进行中）。
  void _onTaskFinished(
    String sessionId,
    String opId,
    String taskId,
    OpTaskStatus status,
  ) {
    final AgentSession? session = _session;
    if (session == null || session.id != sessionId) return;
    final Object? data = status.data;
    unawaited(
      session
          .continueAfterTask(
            taskId,
            opId: opId,
            succeeded: status.succeeded,
            status: <String, Object?>{
              if (status.summary != null) 'summary': status.summary,
              if (data != null) 'data': data,
            },
            summary: status.summary,
          )
          .whenComplete(() => _save(session)),
    );
  }

  /// 没有会话就开一场（[scene] 记进存档，便于操作记录页分组）。
  AgentSession ensureSession({String scene = 'general'}) {
    final AgentSession? existing = _session;
    if (existing != null) return existing;
    final AiProviderConfig? provider = resolveAiAgentProvider(settings);
    if (provider == null) throw StateError('ai_agent_no_provider');
    _scene = scene;
    final AgentSession session = AgentSession(
      id: _newSessionId(),
      llm: _llm(provider),
      toolbox: toolbox,
      host: host,
      clock: _clock,
    );
    _attach(session);
    return session;
  }

  /// 说一句话。没指派提供商时抛 `StateError('ai_agent_no_provider')`——调用方
  /// 在此之前已经用 [hasProvider] 引导用户去设置，这里是兜底，不发请求。
  @override
  Future<void> send(
    String text, {
    AgentUiContext? context,
    List<AiChatImage> images = const <AiChatImage>[],
  }) async {
    final AgentSession session = ensureSession(scene: context?.scene ?? _scene);
    _sessionProfileUid ??= await database.resolveActiveProfileUid();
    unawaited(_pruneOnce());
    try {
      await session.send(text, context: context, images: images);
    } finally {
      await _save(session);
    }
  }

  @override
  void cancel() {
    _session?.cancel();
    host.cancelPending();
  }

  /// 开一场新对话（旧的已在存档里）。
  @override
  Future<void> newSession() async {
    final AgentSession? previous = _session;
    cancel();
    if (previous != null) await _save(previous);
    _detach();
    notifyListeners();
    _sessionsRevision.value++;
  }

  /// 续接一场存档对话（「AI 操作记录」页与控制通道 `ai.ask --resume` 也走这里）。
  /// 切走之前先把当前这场存好；切到的就是当前这场时什么都不做。
  Future<bool> resume(String sessionId) async {
    final AgentSession? current = _session;
    if (current != null && current.id == sessionId) return true;
    final AiProviderConfig? provider = resolveAiAgentProvider(settings);
    final AiAgentSessionRow? row = await database.getAiAgentSession(sessionId);
    if (provider == null || row == null) return false;
    final Object? json;
    try {
      json = jsonDecode(row.payloadJson);
    } on FormatException {
      return false;
    }
    if (json is! Map) return false;
    cancel();
    if (current != null) await _save(current);
    _detach();
    _scene = row.scene;
    _attach(
      AgentSession.fromJson(
        Map<String, Object?>.from(json),
        llm: _llm(provider),
        toolbox: toolbox,
        host: host,
        clock: _clock,
      ),
    );
    _sessionProfileUid = row.profileUid;
    notifyListeners();
    _sessionsRevision.value++;
    return true;
  }

  @override
  Future<bool> switchToSession(String sessionId) => resume(sessionId);

  @override
  Future<List<AiAgentSessionSummary>> listSessions() async =>
      database.listAiAgentSessionSummaries(
        profileUid: await database.resolveActiveProfileUid(),
      );

  @override
  Future<void> renameSession(String sessionId, String title) async {
    final String trimmed = title.trim();
    if (trimmed.isEmpty) return;
    await database.renameAiAgentSession(sessionId, trimmed);
    _sessionsRevision.value++;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    _deletedSessionIds.add(sessionId);
    if (_session?.id == sessionId) {
      cancel();
      _detach();
      notifyListeners();
    }
    await database.deleteAiAgentSession(sessionId);
    _sessionsRevision.value++;
  }

  /// 切过 Profile 之后再打开 AI 助手：手上这场属于别的 Profile（它不会出现在当前
  /// 会话列表里），没在跑就换成一场新对话；归属不明的旧存档、还没说话的新会话不动。
  Future<void> syncWithActiveProfile() async {
    final AgentSession? session = _session;
    final String? owner = _sessionProfileUid;
    if (session == null || running || owner == null || owner.isEmpty) return;
    final String active = await database.resolveActiveProfileUid();
    // 解析期间会话换了 / 开始跑了：以那边为准，不在这里抢着换。
    if (owner == active || !identical(session, _session) || running) return;
    await newSession();
  }

  @override
  Future<AgentUndoResult> undoEntry(String entryId) async {
    final AgentSession? session = _session;
    if (session == null) {
      return const AgentUndoResult(AgentUndoStatus.notUndoable);
    }
    final AgentUndoResult result = await session.undoEntry(entryId);
    await _save(session);
    return result;
  }

  @override
  Future<List<AgentUndoResult>> undoAll() async {
    final AgentSession? session = _session;
    if (session == null) return const <AgentUndoResult>[];
    final List<AgentUndoResult> results = await session.undoAll();
    await _save(session);
    return results;
  }

  AgentLlm _llm(AiProviderConfig provider) {
    final AgentLlm Function(AiProviderConfig provider)? factory = _llmFactory;
    if (factory != null) return factory(provider);
    _client?.close();
    final AiChatClient client = AiChatClient();
    _client = client;
    return AiClientAgentLlm(client: client, provider: provider);
  }

  void _attach(AgentSession session) {
    _session = session;
    _changes = session.changes.listen((_) => notifyListeners());
  }

  void _detach() {
    unawaited(_changes?.cancel());
    _changes = null;
    _session?.dispose();
    _session = null;
    _sessionProfileUid = null;
  }

  /// 存 [session] 这一场（显式传入：在途一轮收尾时当前会话可能已经换成别的）。
  /// 删掉的会话不写回。已不是当前这场时只更新内容（标题 / 归属 / 场景首次落库时
  /// 已定，[FushiDatabase.saveAiAgentSessionSnapshot] 重存不改它们）。
  Future<void> _save(AgentSession session) async {
    if (session.entries.isEmpty || _deletedSessionIds.contains(session.id)) {
      return;
    }
    final bool current = identical(session, _session);
    await saveAiAgentSessionArchive(
      database,
      session,
      scene: current ? _scene : await _archivedSceneOf(session.id),
      now: _clock(),
      profileUid: current ? _sessionProfileUid : null,
    );
    // 控制器已销毁（在途一轮的收尾存档晚到）：存档照写，只是没人再听列表信号。
    if (!_disposed) _sessionsRevision.value++;
  }

  /// 已切走的会话收尾存档时沿用它存档里的场景（没有存档就是还没落过库的新会话）。
  Future<String> _archivedSceneOf(String sessionId) async =>
      (await database.getAiAgentSession(sessionId))?.scene ?? 'general';

  Future<void> _pruneOnce() async {
    if (_pruned) return;
    _pruned = true;
    await database.pruneAiAgentHistory(
      before: _clock()
          .subtract(kAiAgentHistoryRetention)
          .millisecondsSinceEpoch,
    );
  }

  String _newSessionId() {
    final Random random = Random.secure();
    final String suffix = List<String>.generate(
      6,
      (_) => random.nextInt(36).toRadixString(36),
    ).join();
    return 'ai${_clock().millisecondsSinceEpoch.toRadixString(36)}$suffix';
  }

  @override
  void dispose() {
    host.pending.removeListener(notifyListeners);
    _disposed = true;
    cancel();
    _detach();
    _sessionsRevision.dispose();
    _toolbox?.dispose();
    _client?.close();
    super.dispose();
  }
}
