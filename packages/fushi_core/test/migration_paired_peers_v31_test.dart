import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-1017 阶段1：互联 per-peer 授权凭据表 fushi_paired_peers 的建表迁移
/// （v30 -> v31；历史上以旧名 hibiki_paired_peers 建出，v69 起统一新名）与
/// DB 方法的守护测试。
///
/// 覆盖：
/// ① v30 -> 当前 升级：建出 fushi_paired_peers（<31 阶梯按当前 Dart 表定义
///    直接建新名），且旧库既有行零丢（Never break userspace，无损迁移）。
/// ② fresh DB：onCreate 的 createAll 已含新表，多次开库幂等（表已存在不重建）。
/// ③ upsertPairedPeer 幂等（peerId UNIQUE 冲突键整行更新，不新增行）、
///    getPairedPeers 按 pairedAtMs 升序、revokePairedPeer 返回删除行数。
/// ④ 降级（DB 版本 > 代码 schemaVersion）抛 FushiDatabaseDowngradeException。
///
/// 迁移测试沿用 migration_book_key_test 的「手写旧 schema raw seed」范式：只建
/// v30 时已存在的表并写真实行，PRAGMA user_version = 30 触发 onUpgrade(30 -> 当前)。

/// 手写一个 v30 库：epub_books（v16 book-key 形态）+ 一条真实行，user_version=30。
/// 开库触发 onUpgrade(30 -> 当前)，只有 from<31 步会 createTable(fushiPairedPeers)。
FushiDatabase _openMigratedFromV30() {
  return FushiDatabase.forTesting(
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
FushiDatabase _openDowngradedFromFuture() {
  return FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute('''
CREATE TABLE fushi_paired_peers (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  peer_id TEXT NOT NULL UNIQUE,
  device_name TEXT,
  token TEXT NOT NULL,
  paired_at_ms INTEGER NOT NULL,
  last_seen_ip TEXT
)''');
        raw.execute(
          "INSERT INTO fushi_paired_peers "
          "(peer_id, token, paired_at_ms) VALUES ('p-future', 'tok', 1)",
        );
        raw.execute('PRAGMA user_version = 99');
      },
    ),
  );
}

void main() {
  test('v30 -> current creates fushi_paired_peers with zero loss of old rows',
      () async {
    final FushiDatabase db = _openMigratedFromV30();
    addTearDown(db.close);

    // Opening runs onUpgrade(30 -> current). Compare to the live schemaVersion
    // so this never goes stale on a future bump.
    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion,
        reason: 'migration must land on the current schema version');
    // paired peers 表自 v31（TODO-1017 阶段1）引入；断言下界而非瞬时值，
    // 使后续 schema bump 不会把这个迁移守护测试拖 stale。
    expect(db.schemaVersion, greaterThanOrEqualTo(31),
        reason: 'paired peers 表自 v31 引入，schema 版本不应回退到其之前');

    // 终局清算（v69）：走完整阶梯建出的必须是新名，旧名零残留。
    final List<QueryRow> tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('fushi_paired_peers', 'hibiki_paired_peers')",
        )
        .get();
    expect(tables.map((QueryRow r) => r.read<String>('name')).toList(),
        <String>['fushi_paired_peers'],
        reason: '<31 阶梯按当前表定义直接建新名；旧名只允许出现在 v69 改名步里');

    // Old epub_books row survived the upgrade untouched (Never break userspace).
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books.length, 1);
    expect(books.single.bookKey, 'Existing Book');
    expect(books.single.importedAt, 42);

    // The new table now exists and starts empty.
    final List<FushiPairedPeerRow> peers = await db.getPairedPeers();
    expect(peers, isEmpty, reason: '空表 = 无已配对对端 = auth 未接线前行为零变化');
  });

  test('fresh DB has fushi_paired_peers from createAll and is idempotent',
      () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
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
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // Insert two peers OUT of pairedAtMs order to prove the sort.
    await db.upsertPairedPeer(FushiPairedPeersCompanion.insert(
      peerId: 'peer-b',
      token: 'tok-b',
      pairedAtMs: 2000,
      deviceName: const Value('Device B'),
    ));
    await db.upsertPairedPeer(FushiPairedPeersCompanion.insert(
      peerId: 'peer-a',
      token: 'tok-a',
      pairedAtMs: 1000,
    ));

    List<FushiPairedPeerRow> peers = await db.getPairedPeers();
    expect(peers.map((p) => p.peerId).toList(), <String>['peer-a', 'peer-b'],
        reason: 'ordered by pairedAtMs ascending');

    // upsert on the SAME peerId updates the row in place (UNIQUE conflict),
    // never inserts a duplicate.
    await db.upsertPairedPeer(FushiPairedPeersCompanion.insert(
      peerId: 'peer-a',
      token: 'tok-a-rotated',
      pairedAtMs: 1500,
      lastSeenIp: const Value('192.168.1.7'),
    ));
    peers = await db.getPairedPeers();
    expect(peers.length, 2, reason: 'upsert must not create a duplicate row');
    final FushiPairedPeerRow a = peers.firstWhere((p) => p.peerId == 'peer-a');
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
    final FushiDatabase db = _openDowngradedFromFuture();
    addTearDown(db.close);

    await expectLater(
      db.customSelect('PRAGMA user_version').getSingle(),
      throwsA(isA<FushiDatabaseDowngradeException>()
          .having((FushiDatabaseDowngradeException e) => e.dbVersion,
              'dbVersion', 99)
          .having((FushiDatabaseDowngradeException e) => e.appSchemaVersion,
              'appSchemaVersion', db.schemaVersion)),
      reason: 'a newer-schema DB must be refused, never destructively rebuilt',
    );
  });
}
