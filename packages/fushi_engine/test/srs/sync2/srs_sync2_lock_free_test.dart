// 同步 v2 的只读命令不进本机写锁（srs_db_store.dart `kSrsSync2LockFreeOps`）：写锁被占着（复习作答 / 收一批段）
// 时，状态、状态摘要（全库扫描，手机上一两秒）照样跑完；反过来，同步跑摘要的时候作答也不用排在它后面——以前
// 摘要在写锁里，每轮同步都可能让「按下评分键」等一两秒才出下一张。改投影 / 写发件水位的命令仍然排队。
import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_fake_engine.dart';
import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000dd';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> open() async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: 'dev',
      engine: const SrsFakeEngine(),
    );
  }

  test('写锁被占着时，状态与状态摘要照样跑完；改状态的命令仍排在锁后', () async {
    final SrsDbStore s = await open();
    final int now = DateTime.now().millisecondsSinceEpoch;
    await s.sync2Command(<String, Object?>{'op': 'identity', 'now': now});

    final Completer<void> release = Completer<void>();
    final Future<void> held = s.runExclusive(() => release.future);

    final SrsSync2Result status = await s
        .sync2Command(<String, Object?>{'op': 'status'})
        .timeout(const Duration(seconds: 20));
    expect(status.map, isNotEmpty);
    final SrsSync2Result digest = await s
        .sync2Command(<String, Object?>{'op': 'digest', 'now': now})
        .timeout(const Duration(seconds: 20));
    expect(digest.map['digest'], isA<String>());

    bool identityDone = false;
    final Future<void> identity = s
        .sync2Command(<String, Object?>{'op': 'identity', 'now': now})
        .then((_) => identityDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(identityDone, isFalse, reason: '写连接上的命令必须等写锁');

    release.complete();
    await held;
    await identity;
    expect(identityDone, isTrue);
  });

  test('不进写锁的命令只限纯计算与只读已提交快照的命令', () {
    expect(SrsDbStore.kSrsSync2LockFreeOps, <String>{
      'derive_key',
      'seal',
      'open',
      'status',
      'media_known',
      'conflicts',
      'checkpoints',
      'history',
      'digest',
    });
    for (final String op in <String>[
      'identity',
      'plan',
      'outbox',
      'outbox_ack',
      'head',
      'ingest_begin',
      'media_record',
    ]) {
      expect(SrsDbStore.kSrsSync2LockFreeOps, isNot(contains(op)));
    }
  });
}
