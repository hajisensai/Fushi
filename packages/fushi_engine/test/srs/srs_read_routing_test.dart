// Drift 执行器只读（native/fushi_fsrs/src/store/mod.rs `SrsCore::select` / `snapshot_select`，
// srs_database_executor.dart）：查询一律在内核的只读连接上跑、只看已提交的数据；写语句、批量、事务、PRAGMA 抛
// [SrsReadOnlyDatabaseError]，到不了写连接。srs.db 的每一笔写入都是内核命令——这里的造数走测试专用的原始通道
// （`SrsCore.debugExecRaw`）。
// 「写命令攥着写锁时查询照样返回、看不到没提交的行」在 Rust 侧
// `read_pool::tests::queries_see_committed_data_while_a_write_transaction_is_open`。
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow;
import 'package:fushi_core/fushi_core.dart' show SrsUnknownEventsCompanion;
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart' show kSrsReadOnlyExecutor;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

void main() {
  for (final bool inline in <bool>[true, false]) {
    group(inline ? 'inline executor' : 'query lane executor', () {
      late TestSrs s;

      setUp(() async {
        final Directory dir = Directory.systemTemp.createTempSync(
          'srs_read_routing_',
        );
        addTearDown(() {
          try {
            dir.deleteSync(recursive: true);
          } on FileSystemException {
            // 句柄尚未释放；临时目录留给系统清理。
          }
        });
        s = await openTestSrsAt(
          p.join(dir.path, kSrsDatabaseFileName),
          inline: inline,
        );
      });

      Future<int> count() async {
        final QueryRow r = await s.db
            .customSelect('SELECT COUNT(*) AS n FROM srs_unknown_events')
            .getSingle();
        return r.read<int>('n');
      }

      // `last_insert_rowid()` 是每条连接自己的：写连接上插过行后非 0，读连接上恒为 0。
      Future<bool> onWriter() async {
        final QueryRow r = await s.db
            .customSelect('SELECT last_insert_rowid() AS r')
            .getSingle();
        return r.read<int>('r') != 0;
      }

      void insert(String id) => s.core.debugExecRaw(
        'INSERT INTO srs_unknown_events (id, profile_uid, json) '
        "VALUES (?, 'p', '{}')",
        <Object?>[id],
      );

      test('写后立即读得到，查询落在读连接上', () async {
        insert('a');
        // 探针本身分得出两种连接：原始通道在写连接上，刚插过行。
        expect(
          s.core.debugSelectRaw('SELECT last_insert_rowid() AS r').single['r'],
          isNot(0),
        );
        expect(await count(), 1);
        expect(await onWriter(), isFalse);
      });

      test('写语句、批量、事务、PRAGMA 一律被拒，库没动、写连接没留下事务', () async {
        insert('a');
        final Matcher readOnly = throwsA(isA<SrsReadOnlyDatabaseError>());
        // 事务 / 批量：内联执行器上 Drift 先发 BEGIN、被拒后再发 ROLLBACK（同样被拒），抛出来的是包着只读错误的
        // 回滚失败；查询道执行器开事务当场抛只读错误。两种都认，认的是只读错误的消息。
        final Matcher refused = throwsA(
          predicate<Object>((Object e) => '$e'.contains(kSrsReadOnlyExecutor)),
        );
        await expectLater(
          s.db.customStatement(
            'INSERT INTO srs_unknown_events (id, profile_uid, json) '
            "VALUES ('b', 'p', '{}')",
          ),
          readOnly,
        );
        await expectLater(
          s.db
              .into(s.db.srsUnknownEvents)
              .insert(
                SrsUnknownEventsCompanion.insert(
                  id: 'c',
                  profileUid: 'p',
                  json: '{}',
                ),
              ),
          readOnly,
        );
        await expectLater((s.db.delete(s.db.srsUnknownEvents)).go(), readOnly);
        await expectLater(
          s.db.customUpdate("UPDATE srs_unknown_events SET json = '[]'"),
          readOnly,
        );
        await expectLater(
          s.db.batch(
            (b) => b.insert(
              s.db.srsUnknownEvents,
              SrsUnknownEventsCompanion.insert(
                id: 'd',
                profileUid: 'p',
                json: '{}',
              ),
            ),
          ),
          refused,
        );
        await expectLater(s.db.transaction(() => count()), refused);
        // PRAGMA 与 `… RETURNING` 不是只读查询：以前回落到写连接上执行（Drift 靠它开关事务），现在不执行。
        await expectLater(
          s.db.customSelect('PRAGMA wal_autocheckpoint').get(),
          readOnly,
        );
        await expectLater(
          s.db.customStatement('PRAGMA wal_autocheckpoint = 0'),
          readOnly,
        );
        await expectLater(
          s.db
              .customSelect(
                "DELETE FROM srs_unknown_events WHERE id = 'a' RETURNING id",
              )
              .get(),
          readOnly,
        );

        expect(await count(), 1);
        expect(
          s.core
              .debugSelectRaw('SELECT json FROM srs_unknown_events')
              .single['json'],
          '{}',
        );
        expect(s.core.inTransaction, isFalse);
        // 内核的写入照常。
        insert('e');
        expect(await count(), 2);
      });
    });
  }
}
