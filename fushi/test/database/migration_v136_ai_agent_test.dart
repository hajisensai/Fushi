import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v136：AI 助手的对话存档 `ai_agent_sessions` 与操作记录 `ai_agent_actions`
/// （docs/specs/2026-10-26-ai-operations-agent-design.md §5.3 / D3 / D5）。设备本地；
/// 迁移只建表 + 索引、重跑幂等；操作记录不挂外键（会话过期删除后记录仍保留）；
/// prune 只删 [before] 之前的行。
void main() {
  const List<String> tables = <String>['ai_agent_sessions', 'ai_agent_actions'];
  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;
  bool indexExists(sqlite.Database raw, String index) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
    <Object?>[index],
  ).isNotEmpty;

  AiAgentSessionsCompanion session(String id, int at) =>
      AiAgentSessionsCompanion.insert(
        id: id,
        title: 'title $id',
        scene: 'general',
        payloadJson: '{"turns":[]}',
        createdAt: at,
        updatedAt: at,
      );
  AiAgentActionsCompanion action(String sessionId, int at) =>
      AiAgentActionsCompanion.insert(
        sessionId: sessionId,
        opId: 'settings.set',
        argsJson: '{"key":"k"}',
        risk: 'write',
        confirmation: 'auto',
        resultCode: 'ok',
        undoPayloadJson: const Value<String?>('{"old":1}'),
        createdAt: at,
      );

  test('v135 → v136 建两张表与索引；重跑幂等、不清数据', () async {
    final Directory dir = Directory.systemTemp.createTempSync('ai_agent_v136');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags();
    await db.close();

    sqlite.Database raw = sqlite.sqlite3.open(path);
    for (final String t in tables) {
      expect(tableExists(raw, t), isTrue, reason: 'fresh 库 onCreate 建 $t');
      raw.execute('DROP TABLE $t');
    }
    raw.execute('PRAGMA user_version = 135');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 139);
    await migrated.upsertAiAgentSession(session('s1', 10));
    final int actionId = await migrated.insertAiAgentAction(action('s1', 11));
    await migrated.close();

    raw = sqlite.sqlite3.open(path);
    expect(raw.select('PRAGMA user_version').first.values.first, 139);
    for (final String t in tables) {
      expect(tableExists(raw, t), isTrue, reason: t);
    }
    for (final String i in <String>[
      'idx_ai_agent_sessions_updated',
      'idx_ai_agent_actions_session',
      'idx_ai_agent_actions_created',
    ]) {
      expect(indexExists(raw, i), isTrue, reason: i);
    }
    expect(
      raw.select('PRAGMA foreign_key_list(ai_agent_actions)'),
      isEmpty,
      reason: '操作记录不挂外键：会话存档过期删除后记录仍可保留',
    );
    raw.execute('PRAGMA user_version = 135');
    raw.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect((await reopened.getAiAgentSession('s1'))!.title, 'title s1');
    expect((await reopened.getAiAgentAction(actionId))!.opId, 'settings.set');
    await reopened.close();
  });

  test('会话 / 操作记录读写、排序、撤销标记与 prune', () async {
    final Directory dir = Directory.systemTemp.createTempSync('ai_agent_rw');
    addTearDown(() => dir.deleteSync(recursive: true));
    final FushiDatabase db = FushiDatabase.atFile(
      '${dir.path}/t.db',
      isMainProcess: false,
    );
    addTearDown(db.close);

    await db.upsertAiAgentSession(session('old', 100));
    await db.upsertAiAgentSession(session('new', 300));
    // 同 id 覆盖：整场重存，updatedAt 前移。
    await db.upsertAiAgentSession(
      session('old', 100).copyWith(
        updatedAt: const Value<int>(200),
        totalTokens: const Value<int>(42),
      ),
    );
    final List<AiAgentSessionRow> sessions = await db.listAiAgentSessions();
    expect(sessions.map((AiAgentSessionRow r) => r.id), <String>['new', 'old']);
    expect(sessions.last.totalTokens, 42);
    expect(sessions.first.totalTokens, 0, reason: 'totalTokens 默认 0');
    expect(await db.listAiAgentSessions(limit: 1), hasLength(1));

    final int a1 = await db.insertAiAgentAction(action('old', 100));
    final int a2 = await db.insertAiAgentAction(action('old', 250));
    final int a3 = await db.insertAiAgentAction(action('new', 250));
    final int a4 = await db.insertAiAgentAction(action('new', 400));
    expect(
      (await db.listAiAgentActions()).map((AiAgentActionRow r) => r.id),
      <int>[a4, a3, a2, a1],
      reason: 'createdAt 倒序，同一时刻按 id 倒序',
    );
    expect(
      (await db.listAiAgentActions(
        sessionId: 'old',
      )).map((AiAgentActionRow r) => r.id),
      <int>[a2, a1],
    );
    expect(await db.listAiAgentActions(limit: 2), hasLength(2));

    final AiAgentActionRow fresh = (await db.getAiAgentAction(a2))!;
    expect(fresh.undoneAt, isNull);
    expect(fresh.undoStatus, isNull);
    await db.markAiAgentActionUndone(a2, undoneAt: 500, status: 'done');
    final AiAgentActionRow undone = (await db.getAiAgentAction(a2))!;
    expect(undone.undoneAt, 500);
    expect(undone.undoStatus, 'done');

    // 删会话存档不连带操作记录。
    await db.deleteAiAgentSession('new');
    expect(await db.getAiAgentSession('new'), isNull);
    expect(await db.getAiAgentAction(a4), isNotNull);

    // prune：只删 before（不含）之前的会话（updatedAt）与记录（createdAt）。
    await db.upsertAiAgentSession(session('keep', 250));
    final int removed = await db.pruneAiAgentHistory(before: 250);
    expect(removed, 2, reason: '会话 old(200) + 记录 a1(100)');
    expect(await db.getAiAgentSession('old'), isNull);
    expect(await db.getAiAgentSession('keep'), isNotNull);
    expect(await db.getAiAgentAction(a1), isNull);
    expect(
      (await db.listAiAgentActions()).map((AiAgentActionRow r) => r.id),
      <int>[a4, a3, a2],
    );
  });
}
