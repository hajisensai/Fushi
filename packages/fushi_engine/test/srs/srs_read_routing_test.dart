// Drift 执行器的读写分离（native/fushi_fsrs/src/store/mod.rs `SrsCore::select`）：事务外的查询走内核的读连接快照，
// Drift 事务内的查询留在写连接上、读得到同事务刚写的未提交行；事务外的读（读连接上的命令）不读脏数据。
// 不阻塞写锁的那一半（Rust 写命令攥着写锁时查询照样返回）在 Rust 侧
// `read_routing_tests::select_outside_a_drift_transaction_reads_the_committed_snapshot_without_the_write_lock`。
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

void main() {
  for (final bool inline in <bool>[true, false]) {
    group(inline ? 'inline executor' : 'background isolate executor', () {
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

      int committedCount() =>
          s.core
                  .debugQuery('SELECT COUNT(*) AS n FROM srs_unknown_events')
                  .single['n']!
              as int;

      Future<void> insert(String id) => s.db.customStatement(
        'INSERT INTO srs_unknown_events (id, profile_uid, json) '
        "VALUES (?, 'p', '{}')",
        <Object?>[id],
      );

      test('事务外：写后立即读得到，查询落在读连接上', () async {
        await insert('a');
        expect(await count(), 1);
        expect(await onWriter(), isFalse);
      });

      test('Drift 事务内：同事务读得到未提交行；事务外的读看不到；回滚后消失', () async {
        await insert('a');
        await s.db.transaction(() async {
          await insert('b');
          expect(await count(), 2, reason: '事务里读不到自己刚写的行');
          expect(await onWriter(), isTrue, reason: '事务内的查询离开了写连接');
          // 同一时刻读连接上的读：只见已提交的那一行。
          expect(committedCount(), 1, reason: '事务外的读读到了未提交行');
          // 嵌套事务（SAVEPOINT）同样留在写连接上。
          await s.db.transaction(() async {
            await insert('c');
            expect(await count(), 3);
          });
          expect(committedCount(), 1);
        });
        expect(await count(), 3);
        expect(committedCount(), 3);
        expect(await onWriter(), isFalse, reason: '提交后的查询没有回到读连接');

        await expectLater(
          s.db.transaction(() async {
            await insert('d');
            expect(await count(), 4);
            throw StateError('roll back');
          }),
          throwsStateError,
        );
        expect(await count(), 3);
        expect(await onWriter(), isFalse);
      });
    });
  }
}
