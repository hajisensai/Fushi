// 同步 v2 命令与写事务互斥（审查 P1-4）：内核与本机写入共用一条连接，`outbox` / `head` / `plan` / `identity`
// 若不排在写锁后面，会读到另一笔还没提交的 `apply` 事务里的操作；那笔回滚后 seq 被重用、head 代号回退，
// 已发出去的段与 head 让对端判本机分叉。
import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000e9';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('写事务进行中发起的 outbox / identity 排到事务之后：读不到之后回滚掉的操作', () async {
    final SrsStorage st = await openTestSrsStorage();
    final SrsDbStore s = await SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: 'A',
      engine: FfiFsrsEngine.tryCreate(),
    );
    final int seqBefore =
        (await s.sync2Command(<String, Object?>{
              'op': 'identity',
              'now': s.now().$1,
            })).map['nextSeq']!
            as int;

    final List<String> order = <String>[];
    final Completer<void> written = Completer<void>();
    final Completer<void> release = Completer<void>();
    // 一笔写事务：落一条笔记（经 Rust apply 分配了 seq）后停住，随后回滚。
    final Future<void> doomed = s.runExclusive(
      () => s.db.transaction(() async {
        await s.createNote(
          noteTypeId: s.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId(kProfile, 'Expression'): '回滚',
          },
        );
        written.complete();
        await release.future;
        order.add('rolled back');
        throw StateError('roll back on purpose');
      }),
    );
    await written.future;
    // 事务还开着：同步一轮里的命令从独占区外发起。
    final Future<SrsSync2Result> outbox = s
        .sync2Command(<String, Object?>{'op': 'outbox', 'location': 'loc'})
        .whenComplete(() => order.add('outbox'));
    final Future<SrsSync2Result> identity = s
        .sync2Command(<String, Object?>{'op': 'identity', 'now': s.now().$1})
        .whenComplete(() => order.add('identity'));
    // 给不排队的实现充分的机会先跑完（排队的实现无论等多久都不会先跑）。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(order, isEmpty, reason: '命令必须等写事务结束');
    release.complete();
    await expectLater(doomed, throwsStateError);
    final SrsSync2Result out = await outbox;
    final SrsSync2Result id = await identity;
    expect(order.first, 'rolled back');
    expect(id.map['nextSeq'], seqBefore, reason: '回滚掉的操作的 seq 没有被当成已用');
    expect(
      (out.map['upto'] as int?) ?? 0,
      lessThan(seqBefore),
      reason: '发件箱不含回滚掉的操作',
    );
  });
}
