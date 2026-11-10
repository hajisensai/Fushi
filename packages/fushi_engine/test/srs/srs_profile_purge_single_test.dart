// 「删掉一个 uid 在 srs.db 里的全部本机行」只有一份实现（Rust `profile_purge`）：并入（srsMergeProfileUid）
// 与采用（srsAdoptProfileUid / 备份合并改 uid）删旧 uid 时都经它，旧 uid 在每张带 profile_uid 的表、按 profile
// 记的 srs_meta 键、没人引用的 sync2_deps 里一行不剩（BUG 文档见 docs/bugs/，回归）。
//
// 残留按表现查：表清单现查 sqlite_master，不手抄。
import 'dart:async';

import 'package:drift/drift.dart' show QueryRow, Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_merge.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_data.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_profile_merge.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_sync2_peers.dart';
import 'support/srs_test_storage.dart';

/// 目标 uid（并入 / 采用的去处）。
const String _kNewUid = '0193a1b2-0000-7000-8000-00000000cafe';

/// [uid] 在 [db] 里的残留：每张带 `profile_uid` 列的表的行数、按 profile 记的 `srs_meta` 键数（`…/<uid>` 或
/// `…/<uid>/…`）。只列非零项。
Future<Map<String, int>> _residue(SrsDatabase db, String uid) async {
  final Map<String, int> out = <String, int>{};
  final List<String> tables = <String>[
    for (final QueryRow r
        in await db
            .customSelect(
              "SELECT m.name AS n FROM sqlite_master m WHERE m.type = 'table' "
              'AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) p '
              "WHERE p.name = 'profile_uid') ORDER BY m.name",
            )
            .get())
      r.read<String>('n'),
  ];
  expect(tables, contains('sync2_ops'));
  for (final String t in tables) {
    final int n =
        (await db
                .customSelect(
                  'SELECT COUNT(*) AS c FROM "$t" WHERE profile_uid = ?',
                  variables: <Variable<Object>>[
                    Variable<String>(uid, srsIdType),
                  ],
                )
                .getSingle())
            .read<int>('c');
    if (n > 0) out[t] = n;
  }
  final List<String> keys = <String>[
    for (final QueryRow r
        in await db
            .customSelect(
              'SELECT key FROM srs_meta WHERE key LIKE ? OR key LIKE ?',
              variables: <Variable<Object>>[
                Variable<String>('%/$uid'),
                Variable<String>('%/$uid/%'),
              ],
            )
            .get())
      r.read<String>('key'),
  ];
  if (keys.isNotEmpty) out['srs_meta ${keys.join(', ')}'] = keys.length;
  return out;
}

/// 包一层写锁，每次进锁前回调 [onRun]（测试据此知道「这次删除走了写锁」）。
class _ObservedLock implements SrsExclusiveOuter {
  _ObservedLock(this._inner, this.onRun);

  final SrsExclusiveOuter _inner;
  final void Function() onRun;

  @override
  Future<T> run<T>(Future<T> Function() body) {
    onRun();
    return _inner.run(body);
  }
}

/// 没有任何操作引用的因果上下文行数。
Future<int> _unreferencedDeps(SrsDatabase db) async =>
    (await db
            .customSelect(
              'SELECT COUNT(*) AS c FROM sync2_deps '
              'WHERE id NOT IN (SELECT deps FROM sync2_ops)',
            )
            .getSingle())
        .read<int>('c');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FushiDatabase main;
  late SrsStorage srs;
  late int profileId;
  late String oldUid;

  setUp(() async {
    main = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(main.close);
    srs = await openTestSrsStorage();
    final int now = DateTime.now().millisecondsSinceEpoch;
    profileId = await main.insertProfile(
      ProfilesCompanion.insert(name: 'Default', createdAt: now, updatedAt: now),
    );
    oldUid = await main.profileUidOf(profileId);
  });

  Future<SrsDbStore> open(String uid) => SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: uid,
    deviceId: 'devA',
    engine: const SrsFakeEngine(),
  );

  Future<void> addNote(SrsDbStore s, String text) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(s.profileUid, 'Expression'): text,
    },
  );

  test('并入：旧 uid 在每张表、按 profile 的 meta 键、sync2_deps 里都不剩', () async {
    final SrsDbStore s = await open(oldUid);
    await addNote(s, '雨');
    await addNote(s, '風');
    // 发布过：同步留下的位置进度、按 profile 的 meta 键都要一起删。
    expect((await srsSyncOnce(s, SrsMemoryLocationStore())).error, isNull);
    expect(await _residue(srs.db, oldUid), isNotEmpty);
    final int depsBefore = await _unreferencedDeps(srs.db);

    await srsMergeProfileUid(
      main,
      srs.db,
      core: srs.core,
      profileId: profileId,
      oldUid: oldUid,
      newUid: _kNewUid,
      deviceId: 'devA',
    );

    expect(await main.profileUidOf(profileId), _kNewUid);
    expect(await _residue(srs.db, oldUid), isEmpty);
    expect(await _unreferencedDeps(srs.db), lessThanOrEqualTo(depsBefore));
    expect(await _residue(srs.db, _kNewUid), isNotEmpty, reason: '并入的数据在');
  });

  test('采用：旧 uid 的 srs_* / sync2_* 行与 meta 键全删，主库改用新 uid', () async {
    // 只打开过（内置牌组 / 笔记类型经本机写入落成操作）、没有用户笔记、没发布过：可以直接采用。
    await open(oldUid);
    expect(await _residue(srs.db, oldUid), contains('sync2_ops'));
    expect(await srsCanAdoptProfileUid(srs, oldUid), isTrue);
    final int depsBefore = await _unreferencedDeps(srs.db);

    await srsAdoptProfileUid(
      main,
      srs.core,
      profileId: profileId,
      oldUid: oldUid,
      newUid: _kNewUid,
    );

    expect(await main.profileUidOf(profileId), _kNewUid);
    expect(await _residue(srs.db, oldUid), isEmpty);
    expect(await _unreferencedDeps(srs.db), lessThanOrEqualTo(depsBefore));
  });

  test('在调用方的 Drift 事务里删：事务回滚时删除一起回滚', () async {
    final SrsDbStore s = await open(oldUid);
    await addNote(s, '雪');
    final Map<String, int> before = await _residue(srs.db, oldUid);
    expect(before, contains('srs_entities'));

    await expectLater(
      srs.db.transaction(() async {
        // 先在事务里读一下：Drift 的 BEGIN 已经落到写连接上。
        await srs.db.customSelect('SELECT 1').get();
        await srsPurgeProfileRows(srs.core, oldUid);
        expect(await _residue(srs.db, oldUid), isEmpty, reason: '事务里已删');
        throw StateError('abort');
      }),
      throwsStateError,
    );

    expect(await _residue(srs.db, oldUid), before);
  });

  // 采用后重开对不上 → 回退删新 uid（srs_profile_link.dart `_switchUid`）。那一刻旧副本可能已交接作废、新 uid
  // 的副本活着，连接上可能有别的写入者开着 Drift 事务（这里用同一条写连接上另一个 Drift 视图模拟：它的事务跨
  // await 开着）。删除必须在写锁里等它结束，不能夹进去随它回滚。
  test('采用回退：删新 uid 在写锁里等别的写入者的事务结束，不随它回滚', () async {
    final SrsDbStore old = await open(oldUid);
    SrsDbStore current = old;
    final SrsDatabase other = SrsDatabase(srsInlineExecutor(srs.core));
    addTearDown(other.close);
    final Completer<void> otherOpen = Completer<void>();
    final Completer<void> release = Completer<void>();
    Future<void> otherDone = Future<void>.value();
    int locked = 0;
    void releaseOther() {
      if (!release.isCompleted) release.complete();
    }

    int reopens = 0;
    final SrsDbProfileLinker linker = SrsDbProfileLinker(
      db: main,
      activeProfileId: () async => profileId,
      // 第二次进锁就是回退那次删除：放别的写入者收尾（它回滚、放锁），删除排在它之后。
      writeLock: _ObservedLock(SrsCurrentStoreWriteLock(() => current), () {
        if (++locked >= 2) releaseOther();
      }),
      reopenStore: () async {
        reopens++;
        if (reopens == 1) {
          // 新 uid 的副本开了（落下它的内置行），随后另一个写入者在它的独占区里开着一笔 Drift 事务。
          current = await open(_kNewUid);
          otherDone = current
              .runExclusive(
                () => other.transaction(() async {
                  await other.customStatement(
                    'INSERT OR REPLACE INTO srs_meta (key, value) '
                    "VALUES ('purge_probe', '1')",
                  );
                  otherOpen.complete();
                  await release.future;
                  throw StateError('other writer rolls back');
                }),
              )
              .then((_) {}, onError: (Object _) {});
          await otherOpen.future;
          return null; // 重开失败 → 回退
        }
        // 回退里的再次重开：没走写锁的删除此刻已夹进那笔事务，放它回滚。
        releaseOther();
        return old;
      },
    );
    expect(await _residue(srs.db, _kNewUid), isEmpty);

    await expectLater(linker.adopt(old, _kNewUid), throwsStateError);
    await otherDone;

    expect(await main.profileUidOf(profileId), oldUid, reason: '回到原 uid');
    expect(
      await srs.db
          .customSelect("SELECT 1 FROM srs_meta WHERE key = 'purge_probe'")
          .get(),
      isEmpty,
      reason: '别的写入者的事务确实回滚了',
    );
    expect(await _residue(srs.db, _kNewUid), isEmpty, reason: '回退的删除没随别的事务回滚');
  });
}
