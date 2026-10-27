// AI 助手的对话存档与操作记录（v136，docs/specs/2026-10-26-ai-operations-agent-design.md
// §5.3 / D3 / D5）。表语义见 tables.dart 的 AiAgentSessions / AiAgentActions：设备本地，
// 不同步、不进备份、不分 Profile。
part of 'database.dart';

mixin _FushiDbAiAgent on _$FushiDatabase {
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

  /// 写一场会话（同 id 覆盖：每轮对话后整场重存）。
  Future<void> upsertAiAgentSession(AiAgentSessionsCompanion row) =>
      into(aiAgentSessions).insertOnConflictUpdate(row);

  Future<AiAgentSessionRow?> getAiAgentSession(String id) => (select(
    aiAgentSessions,
  )..where((AiAgentSessions t) => t.id.equals(id))).getSingleOrNull();

  /// 最近更新的会话在前。
  Future<List<AiAgentSessionRow>> listAiAgentSessions({int limit = 50}) =>
      (select(aiAgentSessions)
            ..orderBy(<OrderClauseGenerator<AiAgentSessions>>[
              (AiAgentSessions t) => OrderingTerm.desc(t.updatedAt),
              (AiAgentSessions t) => OrderingTerm.desc(t.id),
            ])
            ..limit(limit))
          .get();

  /// 只删会话存档；它名下的操作记录按自己的期限留着（无外键，见表注释）。
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
