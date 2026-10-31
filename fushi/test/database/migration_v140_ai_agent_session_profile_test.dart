import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v140：AI 助手多会话（反馈 uILXKiYRhl）。`ai_agent_sessions` 加 `profile_uid`
/// （会话所属 Profile 的全局身份），存量存档按迁移时的激活 Profile 回填；会话列表
/// 按 Profile 过滤、只投影元数据；整场重存不改写标题 / 归属 / 创建时刻，用户改的
/// 标题不会被下一轮对话冲掉。
void main() {
  const String kAiAgentProfileIndex = 'idx_ai_agent_sessions_profile_updated';

  Set<String> columnsOf(sqlite.Database raw) => <String>{
    for (final sqlite.Row row in raw.select(
      "PRAGMA table_info('ai_agent_sessions')",
    ))
      row['name'] as String,
  };
  bool indexExists(sqlite.Database raw, String index) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
    <Object?>[index],
  ).isNotEmpty;

  Future<int> addProfile(FushiDatabase db, String name, String? uid) =>
      db.insertProfile(
        ProfilesCompanion.insert(
          name: name,
          uid: Value<String?>(uid),
          createdAt: name.codeUnitAt(0),
          updatedAt: name.codeUnitAt(0),
        ),
      );

  /// 建一个当前版本的库，按 [prepare] 写好 Profile / 偏好，再把 ai_agent_sessions
  /// 退回 v139 形态（没有 profile_uid 列与它的索引）并塞两行旧存档。
  Future<String> v139Db(
    Directory dir,
    Future<void> Function(FushiDatabase db) prepare,
  ) async {
    final String path = '${dir.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    // drift 惰性开库：先跑一句把库真正建出来（[prepare] 可能什么都不写）。
    await db.customSelect('SELECT 1').get();
    await prepare(db);
    await db.close();
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP INDEX $kAiAgentProfileIndex');
    raw.execute('ALTER TABLE ai_agent_sessions DROP COLUMN profile_uid');
    for (final String id in <String>['legacy1', 'legacy2']) {
      raw.execute(
        'INSERT INTO ai_agent_sessions (id, title, scene, payload_json, '
        "total_tokens, created_at, updated_at) VALUES (?, 'old $id', "
        "'general', '{}', 7, 10, 20)",
        <Object?>[id],
      );
    }
    raw.execute('PRAGMA user_version = 139');
    expect(columnsOf(raw), isNot(contains('profile_uid')));
    raw.dispose();
    return path;
  }

  group('v139 → v140 迁移', () {
    test('加列 + 索引；存量存档归到激活 Profile；重跑幂等', () async {
      final Directory dir = Directory.systemTemp.createTempSync('ai140');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String path = await v139Db(dir, (FushiDatabase db) async {
        await addProfile(db, 'A', 'uid-a');
        final int b = await addProfile(db, 'B', 'uid-b');
        await db.setPref(kActiveProfileIdPrefKey, '$b');
      });

      FushiDatabase migrated = FushiDatabase.atFile(path, isMainProcess: false);
      expect(migrated.schemaVersion, 140);
      List<AiAgentSessionSummary> all = await migrated
          .listAiAgentSessionSummaries();
      expect(
        all.map((AiAgentSessionSummary s) => s.profileUid).toSet(),
        <String>{'uid-b'},
        reason: '偏好里的激活 Profile（B）还在，就归它',
      );
      expect(all.first.title, startsWith('old '));
      expect(all.first.totalTokens, 7);
      await migrated.close();

      sqlite.Database raw = sqlite.sqlite3.open(path);
      expect(raw.select('PRAGMA user_version').first.values.first, 140);
      expect(columnsOf(raw), contains('profile_uid'));
      expect(indexExists(raw, kAiAgentProfileIndex), isTrue);
      // 重跑 v140 步：列与索引已在，不得报错；已有归属不被改写。
      raw.execute(
        "UPDATE ai_agent_sessions SET profile_uid = 'uid-a' "
        "WHERE id = 'legacy1'",
      );
      raw.execute('PRAGMA user_version = 139');
      raw.dispose();

      migrated = FushiDatabase.atFile(path, isMainProcess: false);
      all = await migrated.listAiAgentSessionSummaries();
      expect(
        <String, String>{
          for (final AiAgentSessionSummary s in all) s.id: s.profileUid,
        },
        <String, String>{'legacy1': 'uid-a', 'legacy2': 'uid-b'},
      );
      await migrated.close();
      raw = sqlite.sqlite3.open(path);
      addTearDown(raw.dispose);
      expect(raw.select('PRAGMA user_version').first.values.first, 140);
    });

    test('偏好指向已删的 Profile：退到最早建的那个', () async {
      final Directory dir = Directory.systemTemp.createTempSync('ai140gone');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String path = await v139Db(dir, (FushiDatabase db) async {
        await addProfile(db, 'A', 'uid-a');
        await db.setPref(kActiveProfileIdPrefKey, '999');
      });
      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      addTearDown(migrated.close);
      expect(
        (await migrated.listAiAgentSessionSummaries())
            .map((AiAgentSessionSummary s) => s.profileUid)
            .toSet(),
        <String>{'uid-a'},
      );
    });

    test('库里没有 Profile：归属留空串（对所有 Profile 可见）', () async {
      final Directory dir = Directory.systemTemp.createTempSync('ai140none');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String path = await v139Db(dir, (FushiDatabase db) async {});
      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      addTearDown(migrated.close);
      final List<AiAgentSessionSummary> all = await migrated
          .listAiAgentSessionSummaries();
      expect(all, hasLength(2));
      expect(
        all.every((AiAgentSessionSummary s) => s.profileUid.isEmpty),
        isTrue,
      );
      // 归属不明的旧存档在任何 Profile 的列表里都看得到。
      expect(
        await migrated.listAiAgentSessionSummaries(profileUid: 'uid-x'),
        hasLength(2),
      );
    });
  });

  group('会话存档 DAO', () {
    late FushiDatabase db;
    late int profileA;
    late int profileB;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      profileA = await addProfile(db, 'A', 'uid-a');
      profileB = await addProfile(db, 'B', 'uid-b');
      await db.setPref(kActiveProfileIdPrefKey, '$profileA');
    });
    tearDown(() => db.close());

    Future<void> save(
      String id, {
      required String title,
      required int at,
      int createdAt = 1,
      String scene = 'general',
      String payload = '{}',
      int tokens = 0,
    }) => db.saveAiAgentSessionSnapshot(
      id: id,
      title: title,
      scene: scene,
      payloadJson: payload,
      totalTokens: tokens,
      createdAt: createdAt,
      updatedAt: at,
    );

    test('首次落库定标题与归属；重存只更新内容，不冲掉改过的标题', () async {
      expect(await db.resolveActiveProfileUid(), 'uid-a');
      await save('s1', title: '把字幕调大', at: 100);
      AiAgentSessionRow row = (await db.getAiAgentSession('s1'))!;
      expect((row.title, row.profileUid, row.createdAt), ('把字幕调大', 'uid-a', 1));

      // 中途切了 Profile、又换了一个「自动标题」重存：归属与标题都不动。
      await db.setPref(kActiveProfileIdPrefKey, '$profileB');
      await save(
        's1',
        title: '别的标题',
        at: 200,
        createdAt: 150,
        scene: 'reader',
        payload: '{"v":2}',
        tokens: 42,
      );
      row = (await db.getAiAgentSession('s1'))!;
      expect(row.title, '把字幕调大');
      expect(row.profileUid, 'uid-a');
      expect(row.createdAt, 1);
      expect(
        (row.scene, row.payloadJson, row.totalTokens, row.updatedAt),
        ('reader', '{"v":2}', 42, 200),
      );

      // 重命名只改标题、不动 updatedAt；之后再重存，改过的标题留着。
      expect(await db.renameAiAgentSession('s1', '字幕设置'), 1);
      row = (await db.getAiAgentSession('s1'))!;
      expect((row.title, row.updatedAt), ('字幕设置', 200));
      await save('s1', title: '把字幕调大', at: 300);
      expect((await db.getAiAgentSession('s1'))!.title, '字幕设置');
      expect(await db.renameAiAgentSession('missing', 'x'), 0);
    });

    test('列表按 Profile 过滤（含归属不明的）、按更新时刻倒序，只投影元数据', () async {
      await save('a-old', title: 'A 旧', at: 100);
      await save('a-new', title: 'A 新', at: 300);
      await db.saveAiAgentSessionSnapshot(
        id: 'b1',
        title: 'B',
        scene: 'general',
        payloadJson: '{}',
        totalTokens: 0,
        createdAt: 1,
        updatedAt: 400,
        profileUid: 'uid-b',
      );
      await db.saveAiAgentSessionSnapshot(
        id: 'orphan',
        title: '旧存档',
        scene: 'general',
        payloadJson: '{}',
        totalTokens: 0,
        createdAt: 1,
        updatedAt: 200,
        profileUid: '',
      );

      List<String> ids(List<AiAgentSessionSummary> list) =>
          list.map((AiAgentSessionSummary s) => s.id).toList();
      expect(
        ids(await db.listAiAgentSessionSummaries(profileUid: 'uid-a')),
        <String>['a-new', 'orphan', 'a-old'],
      );
      expect(
        ids(await db.listAiAgentSessionSummaries(profileUid: 'uid-b')),
        <String>['b1', 'orphan'],
      );
      expect(ids(await db.listAiAgentSessionSummaries()), <String>[
        'b1',
        'a-new',
        'orphan',
        'a-old',
      ]);
      expect(
        await db.listAiAgentSessionSummaries(profileUid: 'uid-a', limit: 1),
        hasLength(1),
      );

      await db.deleteAiAgentSession('a-new');
      expect(
        ids(await db.listAiAgentSessionSummaries(profileUid: 'uid-a')),
        <String>['orphan', 'a-old'],
      );
    });

    test('库里没有 Profile 时激活 uid 为空串', () async {
      final FushiDatabase empty = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(empty.close);
      expect(await empty.resolveActiveProfileUid(), '');
    });
  });

  group('aiAgentSessionAutoTitle', () {
    test('空白折叠、去首尾', () {
      expect(aiAgentSessionAutoTitle('  把字幕\n\n调大\t一点  '), '把字幕 调大 一点');
      expect(aiAgentSessionAutoTitle('   '), '');
    });

    test('超长按码点截断补省略号，不切开代理对', () {
      final String long = '😀' * 70;
      final String title = aiAgentSessionAutoTitle(long);
      expect(title.runes.length, kAiAgentSessionTitleMaxLength + 1);
      expect(title, endsWith('…'));
      expect(title.runes.take(kAiAgentSessionTitleMaxLength).toSet(), <int>{
        '😀'.runes.single,
      });
      final String exact = 'a' * kAiAgentSessionTitleMaxLength;
      expect(aiAgentSessionAutoTitle(exact), exact);
    });
  });
}
