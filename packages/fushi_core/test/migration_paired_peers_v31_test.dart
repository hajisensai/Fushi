import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';

/// 比当前代码 schema 高一级的版本号，用来伪造「未来版本的库」。读 `schemaVersion`
/// 只是取常量 getter，不触发 lazy open，探针实例不建表、不落盘。
final int kFutureSchemaVersion =
    FushiDatabase.forTesting(NativeDatabase.memory()).schemaVersion + 1;

/// TODO-1017 阶段1：互联 per-peer 授权凭据表 fushi_paired_peers（v31 引入；历史上
/// 以旧名 hibiki_paired_peers 建出，v69 起统一新名）与 DB 方法的守护测试。
///
/// 覆盖：
/// ① fresh DB：onCreate 的 createAll 已含新表，多次开库幂等（表已存在不重建）。
/// ② upsertPairedPeer 幂等（peerId UNIQUE 冲突键整行更新，不新增行）、
///    getPairedPeers 按 pairedAtMs 升序、revokePairedPeer 返回删除行数。
/// ③ 降级（DB 版本 > 代码 schemaVersion）抛 FushiDatabaseDowngradeException。
///
/// v30 -> 当前 的升级用例（含 v69 改名）随最低 schema 门槛 v75 一起删除：低于门槛
/// 的库本版本直接拒绝打开（见 migration_min_schema_floor_test）。

/// 手写一个「未来版本」库以强制走降级保护分支。
///
/// 版本号**从代码派生**（[kFutureSchemaVersion] = 当前 schemaVersion + 1），不写死。
/// 这里原本是字面量 99，注释还写着「99 恒大于任何未来 bump 不会 stale」——直到
/// schema 真的升到 99（v98 → v99：每来源资料语言 + 刮削字段锁），99 就不再是未来
/// 版本，`from > to` 分支根本不进，这条守卫在 develop 的 package 测试门上空转。
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
        raw.execute('PRAGMA user_version = $kFutureSchemaVersion');
      },
    ),
  );
}

void main() {
  test(
    'fresh DB has fushi_paired_peers from createAll and is idempotent',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);

      // onCreate's createAll must include the new table; querying it proves it
      // exists without any onUpgrade running.
      expect(await db.getPairedPeers(), isEmpty);
      // Re-querying is a plain no-op; the from<31 guard would only run on upgrade.
      expect(await db.getPairedPeers(), isEmpty);
    },
  );

  test(
    'upsert is idempotent, getPairedPeers sorts by pairedAtMs, revoke counts',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);

      // Insert two peers OUT of pairedAtMs order to prove the sort.
      await db.upsertPairedPeer(
        FushiPairedPeersCompanion.insert(
          peerId: 'peer-b',
          token: 'tok-b',
          pairedAtMs: 2000,
          deviceName: const Value('Device B'),
        ),
      );
      await db.upsertPairedPeer(
        FushiPairedPeersCompanion.insert(
          peerId: 'peer-a',
          token: 'tok-a',
          pairedAtMs: 1000,
        ),
      );

      List<FushiPairedPeerRow> peers = await db.getPairedPeers();
      expect(peers.map((p) => p.peerId).toList(), <String>[
        'peer-a',
        'peer-b',
      ], reason: 'ordered by pairedAtMs ascending');

      // upsert on the SAME peerId updates the row in place (UNIQUE conflict),
      // never inserts a duplicate.
      await db.upsertPairedPeer(
        FushiPairedPeersCompanion.insert(
          peerId: 'peer-a',
          token: 'tok-a-rotated',
          pairedAtMs: 1500,
          lastSeenIp: const Value('192.168.1.7'),
        ),
      );
      peers = await db.getPairedPeers();
      expect(peers.length, 2, reason: 'upsert must not create a duplicate row');
      final FushiPairedPeerRow a = peers.firstWhere(
        (p) => p.peerId == 'peer-a',
      );
      expect(a.token, 'tok-a-rotated');
      expect(a.pairedAtMs, 1500);
      expect(a.lastSeenIp, '192.168.1.7');

      // revoke returns the number of rows deleted.
      expect(await db.revokePairedPeer('peer-a'), 1);
      expect(
        await db.revokePairedPeer('peer-a'),
        0,
        reason: 'revoking an absent peer deletes nothing',
      );
      peers = await db.getPairedPeers();
      expect(peers.map((p) => p.peerId).toList(), <String>['peer-b']);
    },
  );

  test(
    'opening a future-version DB is refused with the downgrade exception',
    () async {
      final FushiDatabase db = _openDowngradedFromFuture();
      addTearDown(db.close);

      await expectLater(
        db.customSelect('PRAGMA user_version').getSingle(),
        throwsA(
          isA<FushiDatabaseDowngradeException>()
              .having(
                (FushiDatabaseDowngradeException e) => e.dbVersion,
                'dbVersion',
                kFutureSchemaVersion,
              )
              .having(
                (FushiDatabaseDowngradeException e) => e.appSchemaVersion,
                'appSchemaVersion',
                db.schemaVersion,
              ),
        ),
        reason:
            'a newer-schema DB must be refused, never destructively rebuilt',
      );
    },
  );
}
