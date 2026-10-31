// AI 助手的对话存档与操作记录（v136，docs/specs/2026-10-26-ai-operations-agent-design.md
// §5.3 / D3 / D5）。表语义见 tables.dart 的 AiAgentSessions / AiAgentActions：设备本地，
// 不同步、不进备份；v141 起会话按 Profile 归属（多会话列表），操作记录不分 Profile。
part of 'database.dart';

/// 会话标题最多多少个字符（按 Unicode 码点数，不切开代理对）。
const int kAiAgentSessionTitleMaxLength = 60;

/// 会话默认标题：首条用户消息的摘要——空白（含换行）折成单个空格、去首尾空白，
/// 超过 [kAiAgentSessionTitleMaxLength] 个码点截断并补「…」。空消息给空串（界面
/// 显示为「新对话」）。
String aiAgentSessionAutoTitle(String firstUserText) {
  final String collapsed = firstUserText.replaceAll(RegExp(r'\s+'), ' ').trim();
  final List<int> runes = collapsed.runes.toList();
  if (runes.length <= kAiAgentSessionTitleMaxLength) return collapsed;
  return '${String.fromCharCodes(runes.take(kAiAgentSessionTitleMaxLength)).trimRight()}…';
}

/// 会话列表的一行：只有元数据，不含整场对话 JSON（列表不必把每场对话都读出来）。
class AiAgentSessionSummary {
  const AiAgentSessionSummary({
    required this.id,
    required this.title,
    required this.scene,
    required this.profileUid,
    required this.totalTokens,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;

  /// 空串 = 还没有标题（界面显示「新对话」）。
  final String title;
  final String scene;

  /// 所属 Profile 的 uid；空串 = 归属不明（对所有 Profile 可见）。
  final String profileUid;
  final int totalTokens;
  final int createdAt;
  final int updatedAt;
}

mixin _FushiDbAiAgent
    on _$FushiDatabase, _FushiDbInfra, _FushiDbSrs, _FushiDbTagsSync {
  Future<void> _ensureAiAgentIndexes() async {
    const List<String> stmts = <String>[
      'CREATE INDEX IF NOT EXISTS idx_ai_agent_sessions_updated '
          'ON ai_agent_sessions (updated_at)',
      'CREATE INDEX IF NOT EXISTS idx_ai_agent_actions_session '
          'ON ai_agent_actions (session_id, created_at)',
      'CREATE INDEX IF NOT EXISTS idx_ai_agent_actions_created '
          'ON ai_agent_actions (created_at)',
    ];
    for (final String stmt in stmts) {
      await customStatement(stmt);
    }
  }

  /// v141：会话列表按 Profile 过滤、按更新时刻倒序。不放进 [_ensureAiAgentIndexes]：
  /// 那个在 v136 步就调，彼时存量表还没有 `profile_uid` 列。
  Future<void> _ensureAiAgentSessionProfileIndex() => customStatement(
    'CREATE INDEX IF NOT EXISTS idx_ai_agent_sessions_profile_updated '
    'ON ai_agent_sessions (profile_uid, updated_at)',
  );

  /// v141 迁移：归属不明（空串）的存量会话归到当前激活 Profile。
  ///
  /// 没有待回填的行就不去解析激活 Profile：迁移阶梯上 `preferences` / `profiles`
  /// 未必存在（只建了部分表的旧库），解析它们只该在真有存量会话要归属时发生。
  Future<void> _backfillAiAgentSessionProfiles() async {
    final TypedResult? pending =
        await (selectOnly(aiAgentSessions)
              ..addColumns(<Expression<Object>>[aiAgentSessions.id])
              ..where(aiAgentSessions.profileUid.equals(''))
              ..limit(1))
            .getSingleOrNull();
    if (pending == null) return;
    if (!await _tableExists('preferences') || !await _tableExists('profiles')) {
      return;
    }
    final String uid = await resolveActiveProfileUid();
    if (uid.isEmpty) return;
    await (update(aiAgentSessions)
          ..where((AiAgentSessions t) => t.profileUid.equals('')))
        .write(AiAgentSessionsCompanion(profileUid: Value<String>(uid)));
  }

  /// 当前激活 Profile 的全局身份（[resolveActiveProfileId] → [profileUidOf]）；库里
  /// 一个 Profile 都没有时（只在纯 DB 测试里出现）为空串。
  Future<String> resolveActiveProfileUid() async {
    final int id = await resolveActiveProfileId();
    if (id <= 0) return '';
    return profileUidOf(id);
  }

  /// 存一场会话的快照（每轮对话后整场重存）。
  ///
  /// 首次落库：写 [title]（调用方用 [aiAgentSessionAutoTitle] 从首条用户消息取）与
  /// 所属 Profile（[profileUid]，省略 = 当前激活 Profile）。之后同 id 重存只更新
  /// 场景、对话 JSON、用量与 [updatedAt]——**标题、归属、创建时刻不动**，用户改过的
  /// 标题不会被下一轮对话冲掉，会话也不会因为中途切了 Profile 而改换门庭。
  Future<void> saveAiAgentSessionSnapshot({
    required String id,
    required String title,
    required String scene,
    required String payloadJson,
    required int totalTokens,
    required int createdAt,
    required int updatedAt,
    String? profileUid,
  }) async {
    final String owner = profileUid ?? await resolveActiveProfileUid();
    await into(aiAgentSessions).insert(
      AiAgentSessionsCompanion.insert(
        id: id,
        title: title,
        scene: scene,
        payloadJson: payloadJson,
        totalTokens: Value<int>(totalTokens),
        createdAt: createdAt,
        updatedAt: updatedAt,
        profileUid: Value<String>(owner),
      ),
      onConflict: DoUpdate(
        (AiAgentSessions old) => AiAgentSessionsCompanion(
          scene: Value<String>(scene),
          payloadJson: Value<String>(payloadJson),
          totalTokens: Value<int>(totalTokens),
          updatedAt: Value<int>(updatedAt),
        ),
      ),
    );
  }

  Future<AiAgentSessionRow?> getAiAgentSession(String id) => (select(
    aiAgentSessions,
  )..where((AiAgentSessions t) => t.id.equals(id))).getSingleOrNull();

  /// 会话列表（最近更新的在前），只投影元数据列。[profileUid] 非空时只列这个
  /// Profile 的会话与归属不明（空串）的会话；null = 全部 Profile（操作记录页配标题用）。
  Future<List<AiAgentSessionSummary>> listAiAgentSessionSummaries({
    String? profileUid,
    int limit = 200,
  }) async {
    final $AiAgentSessionsTable t = aiAgentSessions;
    final JoinedSelectStatement<$AiAgentSessionsTable, AiAgentSessionRow>
    query = selectOnly(t)
      ..addColumns(<Expression<Object>>[
        t.id,
        t.title,
        t.scene,
        t.profileUid,
        t.totalTokens,
        t.createdAt,
        t.updatedAt,
      ]);
    if (profileUid != null) {
      query.where(t.profileUid.isIn(<String>{profileUid, ''}));
    }
    query
      ..orderBy(<OrderingTerm>[
        OrderingTerm.desc(t.updatedAt),
        OrderingTerm.desc(t.id),
      ])
      ..limit(limit);
    final List<TypedResult> rows = await query.get();
    return <AiAgentSessionSummary>[
      for (final TypedResult row in rows)
        AiAgentSessionSummary(
          id: row.read(t.id)!,
          title: row.read(t.title)!,
          scene: row.read(t.scene)!,
          profileUid: row.read(t.profileUid)!,
          totalTokens: row.read(t.totalTokens)!,
          createdAt: row.read(t.createdAt)!,
          updatedAt: row.read(t.updatedAt)!,
        ),
    ];
  }

  /// 用户重命名。只改标题，不动 `updatedAt`（改名不是对话进展，列表顺序不跳）。
  /// 返回改到的行数（0 = 会话已不在）。
  Future<int> renameAiAgentSession(String id, String title) =>
      (update(aiAgentSessions)..where((AiAgentSessions t) => t.id.equals(id)))
          .write(AiAgentSessionsCompanion(title: Value<String>(title)));

  /// 只删会话存档；它名下的操作记录按自己的期限留着（无外键，见表注释），在
  /// 「AI 操作记录」页里仍能撤销。
  Future<void> deleteAiAgentSession(String id) => (delete(
    aiAgentSessions,
  )..where((AiAgentSessions t) => t.id.equals(id))).go();

  /// 写一条操作记录，返回自增 id。
  Future<int> insertAiAgentAction(AiAgentActionsCompanion row) =>
      into(aiAgentActions).insert(row);

  Future<AiAgentActionRow?> getAiAgentAction(int id) => (select(
    aiAgentActions,
  )..where((AiAgentActions t) => t.id.equals(id))).getSingleOrNull();

  /// 最新的操作在前（同一时刻按 id 倒序）；[sessionId] 非空时只列该会话。
  Future<List<AiAgentActionRow>> listAiAgentActions({
    String? sessionId,
    int limit = 200,
  }) {
    final SimpleSelectStatement<$AiAgentActionsTable, AiAgentActionRow> query =
        select(aiAgentActions);
    if (sessionId != null) {
      query.where((AiAgentActions t) => t.sessionId.equals(sessionId));
    }
    query
      ..orderBy(<OrderClauseGenerator<AiAgentActions>>[
        (AiAgentActions t) => OrderingTerm.desc(t.createdAt),
        (AiAgentActions t) => OrderingTerm.desc(t.id),
      ])
      ..limit(limit);
    return query.get();
  }

  /// 记下撤销结果：[status] = `done` | `superseded` | `failed`。
  Future<void> markAiAgentActionUndone(
    int id, {
    required int undoneAt,
    required String status,
  }) => (update(aiAgentActions)..where((AiAgentActions t) => t.id.equals(id)))
      .write(
        AiAgentActionsCompanion(
          undoneAt: Value<int?>(undoneAt),
          undoStatus: Value<String?>(status),
        ),
      );

  /// D3 / D5：删 [before]（毫秒，不含）之前的会话存档（按 `updatedAt`）与操作记录
  /// （按 `createdAt`）。只删记录和快照，不动已生效的改动。返回删掉的行数合计。
  Future<int> pruneAiAgentHistory({required int before}) =>
      transaction(() async {
        final int sessions =
            await (delete(aiAgentSessions)..where(
                  (AiAgentSessions t) => t.updatedAt.isSmallerThanValue(before),
                ))
                .go();
        final int actions =
            await (delete(aiAgentActions)..where(
                  (AiAgentActions t) => t.createdAt.isSmallerThanValue(before),
                ))
                .go();
        return sessions + actions;
      });
}
