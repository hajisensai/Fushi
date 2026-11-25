// 同步 v2 的传输命令读不到没落下的写入（审查 P1-4）：`outbox` / `head` / `plan` / `identity` 读到一笔之后回滚掉的
// `apply` 里的操作的话，那笔回滚后 seq 被重用、head 代号回退，已发出去的段与 head 让对端判本机分叉。
//
// 以前本机写入是一笔跨 await 的 Drift 事务（内核命令嵌在里面），这些命令要排在写锁后面才读不到未提交的操作。现在
// 每条写命令在内核里一次持写锁、一个 SAVEPOINT 做完——提交或整笔回滚都在命令返回之前，Drift 执行器只读、开不出跨
// await 的事务（srs_read_routing_test.dart）。这里钉住剩下的那一半：写命令中途失败，整笔回滚，它分配过的 seq
// 没有被当成已用、发件箱里没有它。
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

  test('写命令中途失败整笔回滚：之后的 outbox / identity 读不到它的操作，seq 不被占', () async {
    final SrsStorage st = await openTestSrsStorage();
    final SrsDbStore s = await SrsDbStore.open(
      core: st.core,
      profileUid: kProfile,
      deviceId: 'A',
      engine: FfiFsrsEngine.tryCreate(),
    );
    Future<int> nextSeq() async =>
        (await s.sync2Command(<String, Object?>{
              'op': 'identity',
              'now': s.now().$1,
            })).map['nextSeq']!
            as int;
    Future<String> addNote(String expression) => s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): expression,
      },
    );
    Future<int> notes() async => (await s.listNotes(limit: 1 << 30)).length;

    final int seqBefore = await nextSeq();
    final Object? opsBefore = (await s.sync2Status())['ops'];
    final int notesBefore = await notes();
    // 这条写命令在落缓存行那一步失败：此前同一个 SAVEPOINT 里已经写下操作（分配了 seq）与投影行。新代的笔记派生表
    // 是 `notes`（native/fushi_fsrs/src/store/gen4/cache.rs；协议 3 是 `srs_notes_cache`），触发器走测试专用的原始通道。
    st.core.debugExecRaw(
      'CREATE TRIGGER test_note_boom BEFORE INSERT ON notes '
      "BEGIN SELECT RAISE(ABORT, 'note refused'); END",
    );
    await expectLater(
      addNote('回滚'),
      throwsA(predicate<Object>((Object e) => '$e'.contains('note refused'))),
    );
    st.core.debugExecRaw('DROP TRIGGER test_note_boom');
    expect(st.core.inTransaction, isFalse);

    expect(await nextSeq(), seqBefore, reason: '回滚掉的操作的 seq 没有被当成已用');
    // 新代的发件走 `sync` 会话（要带进度，协议 3 的 `outbox {location}` 没有了）：这里改看操作日志条数（内核 `status`
    // 的 `ops`）——发件箱是它的子集，日志里没有回滚掉的操作，发件箱也就不会有。
    expect(
      (await s.sync2Status())['ops'],
      opsBefore,
      reason: '操作日志（发件箱的来源）不含回滚掉的操作',
    );
    expect(await notes(), notesBefore);

    // 之后的写入照常，接着用那些 seq。
    await addNote('落库');
    expect(await nextSeq(), greaterThan(seqBefore));
    expect(await notes(), notesBefore + 1);
  });
}
