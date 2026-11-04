/// AI 助手对话存档（`ai_agent_sessions`）的唯一写入口与远端会话的历史面。
///
/// - 本机 AI 页（app 的 `AiAgentController`）、互联 host 上替已配对设备跑的远端会话
///   （app 与 `fushi_server` 的 `AgentAssistantHost` 装配）共用 [saveAiAgentSessionArchive]：
///   同一种标题取法、同一套「首次落库定标题 / 归属 / 发起设备，之后只更新内容」的
///   规矩（[FushiDatabase.saveAiAgentSessionSnapshot]）。
/// - [DatabaseAgentSessionHistory]：互联 host 的远端会话历史（BUG-4067）——按发起设备
///   存、按发起设备列 / 读 / 改名 / 删。app 与服务端同一份实现（两边都是同一张表）。
/// - [AgentLiveSessions]：一个进程里「正打开着」的会话 id。同一场会话只许一处持有
///   ——host 本机正续接着的那场，远端不能再开一份；反过来也一样。两份内存里的会话
///   各自整场重存，后存的会把先存的那几轮冲掉。
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';

/// 互联 host 替已配对设备跑的远端会话存进对话存档时的场景名。
const String kAiAgentRemoteScene = 'remote';

/// 对话存档与操作记录保留多久（spec D3 / D5）。app 本机 AI 页、app 当互联 host、
/// `fushi_server` 当互联 host 三处同一个值（各端 UI 上写的「保留 30 天」就是它）。
const Duration kAiAgentHistoryRetention = Duration(days: 30);

/// 删掉 [now] 往前超过 [kAiAgentHistoryRetention] 的会话存档与操作记录
/// （[FushiDatabase.pruneAiAgentHistory]）。返回删掉的行数合计。
Future<int> pruneAiAgentArchive(
  FushiDatabase database, {
  required DateTime now,
}) => database.pruneAiAgentHistory(
  before: now.subtract(kAiAgentHistoryRetention).millisecondsSinceEpoch,
);

/// 一场会话的默认标题：首条用户消息的摘要（[aiAgentSessionAutoTitle]）。还没有
/// 用户消息时退到第一条条目的文字。
String aiAgentSessionTitleOf(AgentSession session) {
  if (session.entries.isEmpty) return '';
  final AgentEntry first = session.entries.firstWhere(
    (AgentEntry e) => e.kind == AgentEntryKind.user,
    orElse: () => session.entries.first,
  );
  return aiAgentSessionAutoTitle(first.text);
}

/// 把一场会话写进对话存档 `ai_agent_sessions`。没有条目的空会话不落库。
///
/// [profileUid] 省略 = 首次落库时按当前激活 Profile 盖戳；[originPeerId] = 远端会话的
/// 发起设备（只在首次落库时写，空串 = 本机发起）。
Future<void> saveAiAgentSessionArchive(
  FushiDatabase database,
  AgentSession session, {
  required String scene,
  required DateTime now,
  String? profileUid,
  String originPeerId = '',
}) async {
  if (session.entries.isEmpty) return;
  await database.saveAiAgentSessionSnapshot(
    id: session.id,
    title: aiAgentSessionTitleOf(session),
    scene: scene,
    payloadJson: jsonEncode(session.toJson()),
    totalTokens: session.totalTokens,
    createdAt: session.entries.first.createdAt,
    updatedAt: now.millisecondsSinceEpoch,
    profileUid: profileUid,
    originPeerId: originPeerId,
  );
}

/// 一场存档会话读回来的样子：元数据 + 整场对话 JSON（[AgentSession.toJson] 形状）。
class AgentArchivedSession {
  const AgentArchivedSession({
    required this.id,
    required this.title,
    required this.scene,
    required this.originPeerId,
    required this.createdAt,
    required this.updatedAt,
    required this.totalTokens,
    required this.payload,
  });

  final String id;
  final String title;
  final String scene;

  /// 发起设备（空串 = 本机发起 / 认不出）。
  final String originPeerId;
  final int createdAt;
  final int updatedAt;
  final int totalTokens;
  final Map<String, Object?> payload;
}

/// 互联 host 的远端会话存档面（`AgentAssistantHost` 用）。
abstract interface class AgentSessionHistoryStore {
  /// 这次请求用的 per-peer 口令属于哪台已配对设备（`fushi_paired_peers.peer_id`）；
  /// 认不出（已吊销 / 共享口令）→ null。
  Future<String?> peerIdForToken(String peerToken);

  /// 存一场远端会话（每轮之后整场重存）。[originPeerId] 只在首次落库时生效。
  Future<void> save(AgentSession session, {required String originPeerId});

  /// [originPeerId] 发起的会话（最近更新的在前）。
  Future<List<AiAgentSessionSummary>> list(String originPeerId);

  /// 读一场；不在 / 整场 JSON 读不出 → null。
  Future<AgentArchivedSession?> load(String id);

  /// 改标题（去首尾空白后为空不改，返回 false）；会话不在 → false。
  Future<bool> rename(String id, String title);

  Future<void> delete(String id);
}

/// [AgentSessionHistoryStore] 的 Drift 实现：app 与服务端同一张 `ai_agent_sessions`。
class DatabaseAgentSessionHistory implements AgentSessionHistoryStore {
  DatabaseAgentSessionHistory(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final FushiDatabase _db;
  final DateTime Function() _clock;

  @override
  Future<String?> peerIdForToken(String peerToken) async {
    if (peerToken.isEmpty) return null;
    for (final FushiPairedPeerRow peer in await _db.getPairedPeers()) {
      if (peer.token == peerToken) {
        return peer.peerId.isEmpty ? null : peer.peerId;
      }
    }
    return null;
  }

  @override
  Future<void> save(AgentSession session, {required String originPeerId}) =>
      saveAiAgentSessionArchive(
        _db,
        session,
        scene: kAiAgentRemoteScene,
        now: _clock(),
        originPeerId: originPeerId,
      );

  @override
  Future<List<AiAgentSessionSummary>> list(String originPeerId) =>
      _db.listAiAgentSessionSummaries(originPeerId: originPeerId);

  @override
  Future<AgentArchivedSession?> load(String id) async {
    final AiAgentSessionRow? row = await _db.getAiAgentSession(id);
    if (row == null) return null;
    final Object? json;
    try {
      json = jsonDecode(row.payloadJson);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    return AgentArchivedSession(
      id: row.id,
      title: row.title,
      scene: row.scene,
      originPeerId: row.originPeerId,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      totalTokens: row.totalTokens,
      payload: Map<String, Object?>.from(json),
    );
  }

  @override
  Future<bool> rename(String id, String title) async {
    final String trimmed = title.trim();
    if (trimmed.isEmpty) return false;
    return await _db.renameAiAgentSession(id, trimmed) > 0;
  }

  @override
  Future<void> delete(String id) => _db.deleteAiAgentSession(id);
}

/// 一个进程里正打开着的会话 id（见文件头）。app 进程共用一份（本机 AI 页 + 互联
/// host），服务端进程一份。
class AgentLiveSessions {
  final Set<String> _ids = <String>{};

  bool contains(String id) => _ids.contains(id);

  /// 占用 [id]；已被占用返回 false（调用方不得再开一份）。
  bool claim(String id) => _ids.add(id);

  void release(String id) => _ids.remove(id);
}
