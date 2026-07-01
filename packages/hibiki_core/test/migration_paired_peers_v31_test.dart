import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1017 阶段1：互联 per-peer 授权凭据表 hibiki_paired_peers 的建表迁移
/// （v30 -> v31）与 DB 方法的守护测试。
///
/// 覆盖：
/// ① v30 -> v31 升级：建出 hibiki_paired_peers，且旧库既有行零丢（Never break
///    userspace，无损迁移）。
/// ② fresh DB：onCreate 的 createAll 已含新表，多次开库幂等（表已存在不重建）。
/// ③ upsertPairedPeer 幂等（peerId UNIQUE 冲突键整行更新，不新增行）、
///    getPairedPeers 按 pairedAtMs 升序、revokePairedPeer 返回删除行数。
/// ④ 降级（DB 版本 > 代码 schemaVersion）抛 HibikiDatabaseDowngradeException。
///
/// 迁移测试沿用 migration_book_key_test 的「手写旧 schema raw seed」范式：只建
/// v30 时已存在的表并写真实行，PRAGMA user_version = 30 触发 onUpgrade(30 -> 当前)。

/// 手写一个 v30 库：epub_books（v16 book-key 形态）+ 一条真实行，user_version=30。
/// 开库触发 onUpgrade(30 -> 当前)，只有 from<31 步会 createTable(hibikiPairedPeers)。
HibikiDatabase _openMigratedFromV30() {
  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute('PRAGMA foreign_keys = ON');
        raw.execute('''
CREATE TABLE epub_books (
  book_key TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  author TEXT,
  cover_path TEXT,
  epub_path TEXT NOT NULL,
  extract_dir TEXT NOT NULL,
  chapter_count INTEGER NOT NULL,
  chapters_json TEXT NOT NULL,
  toc_json TEXT,
  source_metadata TEXT,
  source_id INTEGER,
  imported_at INTEGER NOT NULL
)''');
        raw.execute(
          "INSERT INTO epub_books "
          "(book_key, title, epub_path, extract_dir, chapter_count, chapters_json, imported_at) "
          "VALUES ('Existing Book', 'Existing Book', '/x.epub', '/x', 0, '[]', 42)",
        );
        raw.execute('PRAGMA user_version = 30');
      },
    ),
  );
}

/// 手写一个「未来版本」库（user_version = 99 > 代码 schemaVersion）以强制走降级
/// 保护分支，且 99 恒大于任何未来 bump 不会 stale。
HibikiDatabase _openDowngradedFromFuture() {
  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute('''
CREATE TABLE hibiki_paired_peers (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  peer_id TEXT NOT NULL UNIQUE,
  device_name TEXT,
  token TEXT NOT NULL,
  paired_at_ms INTEGER NOT NULL,
  last_seen_ip TEXT
)''');
        raw.execute(
          "INSERT INTO hibiki_paired_peers "
          "(peer_id, token, paired_at_ms) VALUES ('p-future', 'tok', 1)",
        );
        raw.execute('PRAGMA user_version = 99');
      },
    ),
  );
}

void main() {
  test('v30 -> v31 creates hibiki_paired_peers with zero loss of old rows',
      () async {
    final HibikiDatabase db = _openMigratedFromV30();
    addTearDown(db.close);

    // Opening runs onUpgrade(30 -> current). Compare to the live schemaVersion
    // so this never goes stale on a future bump.
    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion,
        reason: 'migration must land on the current schema version');
    expect(db.schemaVersion, 31, reason: 'TODO-1017 阶段1 bump 到 v31');

    // Old epub_books row survived the upgrade untouched (Never break userspace).
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books.length, 1);
    expect(books.single.bookKey, 'Existing Book');
    expect(books.single.importedAt, 42);

    // The new table now exists and starts empty.
    final List<HibikiPairedPeerRow> peers = await db.getPairedPeers();
    expect(peers, isEmpty, reason: '空表 = 无已配对对端 = auth 未接线前行为零变化');
  });

  test('fresh DB has hibiki_paired_peers from createAll and is idempotent',
      () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // onCreate's createAll must include the new table; querying it proves it
    // exists without any onUpgrade running.
    expect(await db.getPairedPeers(), isEmpty);
    // Re-querying is a plain no-op; the from<31 guard would only run on upgrade.
    expect(await db.getPairedPeers(), isEmpty);
  });

  test(
      'upsert is idempotent, getPairedPeers sorts by pairedAtMs, revoke counts',
      () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // Insert two peers OUT of pairedAtMs order to prove the sort.
    await db.upsertPairedPeer(HibikiPairedPeersCompanion.insert(
      peerId: 'peer-b',
      token: 'tok-b',
      pairedAtMs: 2000,
      deviceName: const Value('Device B'),
    ));
    await db.upsertPairedPeer(HibikiPairedPeersCompanion.insert(
      peerId: 'peer-a',
      token: 'tok-a',
      pairedAtMs: 1000,
    ));

    List<HibikiPairedPeerRow> peers = await db.getPairedPeers();
    expect(peers.map((p) => p.peerId).toList(), <String>['peer-a', 'peer-b'],
        reason: 'ordered by pairedAtMs ascending');

    // upsert on the SAME peerId updates the row in place (UNIQUE conflict),
    // never inserts a duplicate.
    await db.upsertPairedPeer(HibikiPairedPeersCompanion.insert(
      peerId: 'peer-a',
      token: 'tok-a-rotated',
      pairedAtMs: 1500,
      lastSeenIp: const Value('192.168.1.7'),
    ));
    peers = await db.getPairedPeers();
    expect(peers.length, 2, reason: 'upsert must not create a duplicate row');
    final HibikiPairedPeerRow a = peers.firstWhere((p) => p.peerId == 'peer-a');
    expect(a.token, 'tok-a-rotated');
    expect(a.pairedAtMs, 1500);
    expect(a.lastSeenIp, '192.168.1.7');

    // revoke returns the number of rows deleted.
    expect(await db.revokePairedPeer('peer-a'), 1);
    expect(await db.revokePairedPeer('peer-a'), 0,
        reason: 'revoking an absent peer deletes nothing');
    peers = await db.getPairedPeers();
    expect(peers.map((p) => p.peerId).toList(), <String>['peer-b']);
  });

  test('opening a future-version DB is refused with the downgrade exception',
      () async {
    final HibikiDatabase db = _openDowngradedFromFuture();
    addTearDown(db.close);

    await expectLater(
      db.customSelect('PRAGMA user_version').getSingle(),
      throwsA(isA<HibikiDatabaseDowngradeException>()
          .having((HibikiDatabaseDowngradeException e) => e.dbVersion,
              'dbVersion', 99)
          .having((HibikiDatabaseDowngradeException e) => e.appSchemaVersion,
              'appSchemaVersion', db.schemaVersion)),
      reason: 'a newer-schema DB must be refused, never destructively rebuilt',
    );
  });
}
