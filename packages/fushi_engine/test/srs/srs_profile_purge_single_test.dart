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
import 'package:fushi_engine/srs/srs_db_store.dart';
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

  // 采用删旧 uid（srs_profile_link.dart `_switchUid`）在旧副本的最后一段独占区里跑、之后副本作废
  // （[SrsDbStore.retire]）：副本上在途的写入先写完再删；之后再来的写入明确失败，不会把行写回已删的 uid（内核写
  // 本机状态行时没有行就新建：一条漏进来的写入会让退役的 uid 重新长出数据）。以前靠套在全部副本外面的一把写锁，
  // 那把锁随 Drift 事务一起删了。
  test('采用：删旧 uid 排在旧副本在途写入之后，删完副本作废、迟到的写入明确失败', () async {
    final SrsDbStore old = await open(oldUid);
    final List<String> order = <String>[];
    final Completer<void> entered = Completer<void>();
    final Completer<void> release = Completer<void>();
    // 在途写入：占着旧副本的独占区。
    final Future<void> inFlight = old.runExclusive(() async {
      entered.complete();
      await release.future;
      order.add('write');
    });
    await entered.future;
    final SrsDbProfileLinker linker = SrsDbProfileLinker(
      db: main,
      activeProfileId: () async => profileId,
      reopenStore: () async {
        order.add('reopen');
        return open(await main.profileUidOf(profileId));
      },
    );
    final Future<SrsProfileAdoptResult> adopting = linker.adopt(old, _kNewUid);
    // 给不排队的实现充分的机会先删（排队的实现无论等多久都不会先删）。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(order, isEmpty);
    expect(await _residue(srs.db, oldUid), isNotEmpty, reason: '在途写入还没做完就删了');
    expect(await main.profileUidOf(profileId), oldUid);
    release.complete();
    await inFlight;
    final SrsProfileAdoptResult result = await adopting;

    expect(order, <String>['write', 'reopen']);
    expect(result.store.profileUid, _kNewUid);
    expect(await main.profileUidOf(profileId), _kNewUid);
    expect(old.isUsable, isFalse);
    await expectLater(
      addNote(old, '迟到'),
      throwsA(
        isA<SrsStoreRetiredError>().having(
          (SrsStoreRetiredError e) => e.message,
          'message',
          contains('adopted the uid'),
        ),
      ),
    );
    expect(
      await _residue(srs.db, oldUid),
      isEmpty,
      reason: '迟到的写入把行写回了已删的 uid',
    );
    expect(await _residue(srs.db, _kNewUid), isNotEmpty);
  });

  // 采用后重开的新副本没法用（这里让它的重建失败）→ 回退删新 uid。新 uid 的副本活着：删除在它的最后一段独占区
  // 里跑、随后作废它，同样不与它自己的写入交错。
  test('采用回退：删新 uid 在新副本的最后一段独占区里跑并作废它，回到原 uid', () async {
    final SrsDbStore old = await open(oldUid);
    SrsDbStore? fresh;
    int reopens = 0;
    final SrsDbProfileLinker linker = SrsDbProfileLinker(
      db: main,
      activeProfileId: () async => profileId,
      reopenStore: () async {
        reopens++;
        if (reopens == 1) {
          final SrsDbStore s = fresh = await open(_kNewUid);
          // 之后的 afterRestore（重建缓存，连同本机状态行一个 SAVEPOINT）失败。
          for (final String on in const <String>['INSERT', 'UPDATE']) {
            srs.core.debugExecRaw(
              'CREATE TRIGGER test_restore_boom_$on BEFORE $on ON srs_local_state '
              "BEGIN SELECT RAISE(ABORT, 'restore refused'); END",
            );
          }
          return s;
        }
        for (final String on in const <String>['INSERT', 'UPDATE']) {
          srs.core.debugExecRaw('DROP TRIGGER IF EXISTS test_restore_boom_$on');
        }
        return open(await main.profileUidOf(profileId));
      },
    );
    expect(await _residue(srs.db, _kNewUid), isEmpty);

    await expectLater(
      linker.adopt(old, _kNewUid),
      throwsA(
        predicate<Object>((Object e) => '$e'.contains('restore refused')),
      ),
    );

    expect(reopens, 2);
    expect(await main.profileUidOf(profileId), oldUid, reason: '回到原 uid');
    expect(await _residue(srs.db, _kNewUid), isEmpty);
    expect(fresh!.isUsable, isFalse);
    await expectLater(
      addNote(fresh!, '迟到'),
      throwsA(
        isA<SrsStoreRetiredError>().having(
          (SrsStoreRetiredError e) => e.message,
          'message',
          contains('was rolled back'),
        ),
      ),
    );
    expect(await _residue(srs.db, _kNewUid), isEmpty);
    expect(await _residue(srs.db, oldUid), isNotEmpty, reason: '原 uid 重开后内置行在');
  });
}
