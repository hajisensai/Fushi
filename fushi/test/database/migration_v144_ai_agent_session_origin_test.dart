import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v144：`ai_agent_sessions` 加 `origin_peer_id`（远端会话由哪台已配对设备发起，
/// BUG-4067）。
///
/// 承重的是升级语义：老版本存远端会话时没记发起设备，存量会话必须读成空串
/// （认不出设备）——按发起设备过滤的历史列表一条都不给，不能猜着把别人的对话交给
/// 某台设备；本机会话列表照常列出它们。首次落库定下的发起设备之后重存不改。
void main() {
  const String kOriginIndex = 'idx_ai_agent_sessions_origin_updated';

  Set<String> columnsOf(sqlite.Database raw) => <String>{
    for (final sqlite.Row row in raw.select(
      "PRAGMA table_info('ai_agent_sessions')",
    ))
      row['name'] as String,
  };
  bool indexExists(sqlite.Database raw) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
    <Object?>[kOriginIndex],
  ).isNotEmpty;

  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.customSelect('SELECT 1').get();
    await original.close();
    return path;
  }

  test('v143 → v144：存量远端会话读成「认不出发起设备」，不进任何设备的历史列表', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'aiorigin144',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP INDEX $kOriginIndex');
    raw.execute('ALTER TABLE ai_agent_sessions DROP COLUMN origin_peer_id');
    raw.execute(
      'INSERT INTO ai_agent_sessions (id, title, scene, payload_json, '
      'total_tokens, created_at, updated_at, profile_uid) VALUES '
      "('old-remote', '对端的旧会话', 'remote', '{}', 3, 10, 20, ''), "
      "('old-local', '本机的旧会话', 'general', '{}', 4, 11, 21, '')",
    );
    raw.execute('PRAGMA user_version = 143');
    expect(columnsOf(raw), isNot(contains('origin_peer_id')));
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 146);
    final List<AiAgentSessionSummary> all = await migrated
        .listAiAgentSessionSummaries();
    expect(
      <String, String>{
        for (final AiAgentSessionSummary s in all) s.id: s.originPeerId,
      },
      <String, String>{'old-remote': '', 'old-local': ''},
    );
    expect(
      await migrated.listAiAgentSessionSummaries(originPeerId: 'phone-1'),
      isEmpty,
      reason: '老会话没记发起设备：不能猜着列给任何一台',
    );
    expect(
      () => migrated.listAiAgentSessionSummaries(originPeerId: ''),
      throwsArgumentError,
      reason: '空串不是合法过滤值，否则会把认不出设备的会话全交出去',
    );

    // 新存的远端会话盖上发起设备；之后重存（哪怕调用方给了别的值）不改。
    await migrated.saveAiAgentSessionSnapshot(
      id: 'new-remote',
      title: '手机的会话',
      scene: 'remote',
      payloadJson: '{}',
      totalTokens: 1,
      createdAt: 30,
      updatedAt: 40,
      profileUid: '',
      originPeerId: 'phone-1',
    );
    await migrated.saveAiAgentSessionSnapshot(
      id: 'new-remote',
      title: 'ignored',
      scene: 'remote',
      payloadJson: '{"v":1}',
      totalTokens: 2,
      createdAt: 30,
      updatedAt: 50,
      profileUid: '',
    );
    final List<AiAgentSessionSummary> mine = await migrated
        .listAiAgentSessionSummaries(originPeerId: 'phone-1');
    expect(mine.map((AiAgentSessionSummary s) => s.id), <String>['new-remote']);
    expect(mine.single.originPeerId, 'phone-1');
    expect(mine.single.updatedAt, 50);
    expect(
      (await migrated.getAiAgentSession('new-remote'))!.originPeerId,
      'phone-1',
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 146);
    expect(columnsOf(probe), contains('origin_peer_id'));
    expect(indexExists(probe), isTrue);
  });

  test('v144 步幂等：列已在（按当前定义建的表）时跳过，已有行不丢', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'aiorigin144idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute(
      'INSERT INTO ai_agent_sessions (id, title, scene, payload_json, '
      'total_tokens, created_at, updated_at, profile_uid, origin_peer_id) '
      "VALUES ('kept', 't', 'remote', '{}', 0, 1, 2, '', 'peer-x')",
    );
    raw.execute('PRAGMA user_version = 143');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(
      (await migrated.listAiAgentSessionSummaries(
        originPeerId: 'peer-x',
      )).single.id,
      'kept',
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 146);
  });
}
