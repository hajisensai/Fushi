import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// Fushi 终局清算 W1（v68 -> v69）：hibiki_paired_peers -> fushi_paired_peers
/// 表改名迁移的守护测试。
///
/// 覆盖：
/// ① v68 -> v69 升级：旧名表被 ALTER TABLE RENAME 成新名，既有配对行零丢
///    （含 UNIQUE(peer_id) 约束随表迁移，Never break userspace）。
/// ② 幂等：改名后的库再走一次升级路径（user_version 回拨模拟重复升级）不
///    重建、不丢行。
///
/// 迁移测试沿用 migration_paired_peers_v31_test 的「手写旧 schema raw seed」
/// 范式：只建 v68 时真实存在形态的旧名表并写真实行，PRAGMA user_version = 68
/// 触发 onUpgrade(68 -> 当前)，只有 from<69 的改名步会跑。
/// NativeDatabase.memory() 默认关外键，按仓库纪律显式 PRAGMA foreign_keys=ON。

/// 手写一个 v68 库：旧名 hibiki_paired_peers（v31 引入以来的真实列形态）+
/// 两条真实配对行，user_version=68。
FushiDatabase _openMigratedFromV68() {
  return FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute('PRAGMA foreign_keys = ON');
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
          "(peer_id, device_name, token, paired_at_ms, last_seen_ip) VALUES "
          "('peer-a', 'Device A', 'tok-a', 1000, '192.168.1.7'), "
          "('peer-b', NULL, 'tok-b', 2000, NULL)",
        );
        raw.execute('PRAGMA user_version = 68');
      },
    ),
  );
}

Future<List<String>> _pairedPeerTableNames(FushiDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name IN ('fushi_paired_peers', 'hibiki_paired_peers') ORDER BY name",
      )
      .get();
  return rows.map((QueryRow r) => r.read<String>('name')).toList();
}

void main() {
  test('v68 -> v69 renames hibiki_paired_peers with zero loss of rows',
      () async {
    final FushiDatabase db = _openMigratedFromV68();
    addTearDown(db.close);

    final QueryRow ver =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(ver.read<int>('user_version'), db.schemaVersion,
        reason: 'migration must land on the current schema version');
    expect(db.schemaVersion, greaterThanOrEqualTo(69),
        reason: '表改名自 v69 引入，schema 版本不应回退到其之前');

    // 旧名消失、新名出现（纯 RENAME，不是 drop+create）。
    expect(await _pairedPeerTableNames(db), <String>['fushi_paired_peers'],
        reason: 'ALTER TABLE RENAME 后旧名必须零残留');

    // 既有配对行零丢，且经 DAO（新名表）读出的值逐列一致。
    final List<FushiPairedPeerRow> peers = await db.getPairedPeers();
    expect(peers.length, 2, reason: '改名不得丢行');
    expect(peers[0].peerId, 'peer-a');
    expect(peers[0].deviceName, 'Device A');
    expect(peers[0].token, 'tok-a');
    expect(peers[0].pairedAtMs, 1000);
    expect(peers[0].lastSeenIp, '192.168.1.7');
    expect(peers[1].peerId, 'peer-b');
    expect(peers[1].token, 'tok-b');

    // UNIQUE(peer_id) 约束随表迁移：同 peerId upsert 仍是整行更新不加行。
    await db.upsertPairedPeer(FushiPairedPeersCompanion.insert(
      peerId: 'peer-a',
      token: 'tok-a-rotated',
      pairedAtMs: 1500,
    ));
    final List<FushiPairedPeerRow> after = await db.getPairedPeers();
    expect(after.length, 2, reason: 'peer_id UNIQUE 必须在改名后继续生效');
    expect(
        after.firstWhere((p) => p.peerId == 'peer-a').token, 'tok-a-rotated');
  });

  test('rename step is idempotent when the new-name table already exists',
      () async {
    // 模拟「已经改过名的库再次走升级路径」：新名表已在、旧名不在，
    // user_version 68 触发 from<69 —— 守卫必须 no-op 而不是报错/重建。
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (raw) {
          raw.execute('PRAGMA foreign_keys = ON');
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
            "(peer_id, token, paired_at_ms) VALUES ('peer-kept', 'tok', 7)",
          );
          raw.execute('PRAGMA user_version = 68');
        },
      ),
    );
    addTearDown(db.close);

    final List<FushiPairedPeerRow> peers = await db.getPairedPeers();
    expect(peers.length, 1, reason: '重复升级不得动已改名表的行');
    expect(peers.single.peerId, 'peer-kept');
    expect(await _pairedPeerTableNames(db), <String>['fushi_paired_peers']);
  });
}
