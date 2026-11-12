// 收掉 Dart 写路径的第 12 步：本机状态行（srs_local_state.json）只由内核写
// （native/fushi_fsrs/src/store/local_state.rs）。Dart 不再整行重写、命令也不再带整行：修订号 / 纪元 / 样式去重游标由
// 内核持有并在回包里带回，校时状态随命令或经 `local_anchor` 交给内核。这里钉住：
//
// - 校时、待回收集合、缓存推导口径版本各写各的键，互不抹掉；校时不经 Drift 写；
// - 开库把行与纪元落下（新 profile、覆盖恢复之后、老行没纪元），而且排在缓存重建之后；
// - 指向同一个 profile 的两个副本对象交替写：修订号从库里的值推进，不回退；没校过时的那个不抹掉另一个写下的校时状态；
// - 重读路径（`reloadLocal`）只读，不把删掉的行建回来；
// - 改投影的命令回包缺 `localRevision` / `localEpoch` 是契约错误。
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsDatabase;
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_bulk_fixture.dart';
import 'support/srs_test_storage.dart';

const String kUid = '01928c3e-0000-7000-8000-00000000d7a5';

/// 墙钟 1000、开机时钟 [boot]（可调）的时钟；[bootId] 区分「进程」。
SrsTrustedClock _clock(String bootId, {int Function()? boot}) =>
    SrsTrustedClock(
      wallClockMs: () => 1000,
      bootClockMs: boot ?? () => 50,
      bootId: bootId,
    );

Future<SrsDbStore> _open(SrsStorage storage, {SrsTrustedClock? clock}) =>
    SrsDbStore.open(
      db: storage.db,
      core: storage.core,
      profileUid: kUid,
      deviceId: 'dev',
      engine: const FakeFsrsEngine(),
      trustedClock: clock,
      fallbackRolloverHour: () => 4,
    );

/// 库里的本机状态行；没有为 null。
Future<Map<String, Object?>?> _row(SrsStorage storage) => _rowOf(storage.db);

Future<Map<String, Object?>?> _rowOf(SrsDatabase db) async {
  final List<String> rows = <String>[
    for (final r
        in await db.customSelect('SELECT json FROM srs_local_state').get())
      r.read<String>('json'),
  ];
  expect(rows.length, lessThanOrEqualTo(1));
  return rows.isEmpty ? null : jsonDecode(rows.single) as Map<String, Object?>;
}

Future<int> _count(SrsDatabase db, String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle())
        .read<int>('c');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('校时、待回收集合、缓存版本各写各的键，互不抹掉；校时是一条内核命令、不经 Drift 写', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore s = await _open(storage, clock: _clock('boot-a'));
    // 开库就把行落下了：纪元、当前缓存推导口径版本。
    final Map<String, Object?> opened = (await _row(storage))!;
    expect(opened['epoch'], isA<String>());
    expect(opened['cacheRev'], s.debugCacheRevision);

    final int commands = s.debugCoreCommands;
    SrsRustDelegate.debugStatements = 0;
    await s.anchorTime(1700000000000, observedAtBootMs: 20);
    // ignore: avoid_print
    print(
      'WRITE_COST anchorTime: statements=${SrsRustDelegate.debugStatements} '
      'core=${s.debugCoreCommands - commands}',
    );
    expect(SrsRustDelegate.debugStatements, 0);
    expect(s.debugCoreCommands - commands, 1);
    // o = 可信时间 − 墙钟 = 1700000000000 + (50 − 20) − 1000。
    expect((await _row(storage))!['anchor'], <String, Object?>{
      'o': 1700000000030 - 1000,
      'b': 'boot-a',
      's': 1700000000000,
      't': 20,
    });

    expect(await s.queueMediaGc(<String>['a.png']), <String>{'a.png'});
    // 库里多出一个这一版不认识的键（更新的版本写下的）：内核读改写整行，原样留着。
    storage.core.debugExecRaw(
      r"UPDATE srs_local_state SET json = json_set(json, '$.stray', 1, '$.cacheRev', 5)",
    );
    await s.anchorTime(1700000001000, observedAtBootMs: 30);
    await s.sync2Checkpoint('m', 'manual');
    final Map<String, Object?> after = (await _row(storage))!;
    expect(after['stray'], 1);
    expect(after['cacheRev'], 5);
    expect(after['mediaGc'], <Object?>['a.png']);
    expect(await s.pendingMediaGc(), <String>{'a.png'});
    expect((after['anchor']! as Map<String, Object?>)['s'], 1700000001000);
    expect(after['epoch'], opened['epoch']);
    expect(after['revision'], s.revision);
    expect(await s.changeFingerprint(), '${opened['epoch']}:${s.revision}');
  });

  test('覆盖恢复之后：重建缓存只做一次，行在重建之后落下，纪元不再每次开库都换', () async {
    final BulkFixture f = await BulkFixture.open(notes: 3);
    final SrsDatabase db = f.db;
    Future<SrsDbStore> open() => SrsDbStore.open(
      db: db,
      core: f.store.core,
      profileUid: kBulkUid,
      deviceId: 'dev',
      engine: const FakeFsrsEngine(),
      trustedClock: fixedTrustedClock(),
      fallbackRolloverHour: () => 4,
    );
    final String epoch0 = (await _rowOf(db))!['epoch']! as String;
    final int cards = await _count(db, 'srs_cards_cache');
    final int notes = await _count(db, 'srs_notes_cache');
    expect(cards, 6);
    expect(notes, 3);
    // 样式去重游标推进过（恢复后要归零）。
    f.store.core.debugExecRaw(
      r"UPDATE srs_local_state SET json = json_set(json, '$.styleCursor', 9)",
    );

    // 恢复备份：本机状态行与缓存表被清空（备份快照剥掉设备本地表）。
    f.store.core.debugExecRaw('DELETE FROM srs_local_state');
    f.store.core.debugExecRaw('DELETE FROM srs_cards_cache');
    f.store.core.debugExecRaw('DELETE FROM srs_notes_cache');
    // 重建途中失败：行还不存在，下次开库照样判成「刚恢复」再来一遍。
    f.store.core.debugExecRaw(
      'CREATE TRIGGER test_rebuild_boom BEFORE INSERT ON srs_notes_cache '
      "BEGIN SELECT RAISE(ABORT, 'rebuild refused'); END",
    );
    await expectLater(
      open(),
      throwsA(
        predicate((Object e) => '$e'.contains('rebuild refused'), 'rebuild'),
      ),
    );
    expect(await _rowOf(db), isNull);
    expect(await _count(db, 'srs_notes_cache'), 0);
    f.store.core.debugExecRaw('DROP TRIGGER test_rebuild_boom');

    final SrsDbStore restored = await open();
    final Map<String, Object?> row1 = (await _rowOf(db))!;
    final String epoch1 = row1['epoch']! as String;
    expect(epoch1, isNot(epoch0), reason: '本机状态重建后换纪元');
    expect(row1.containsKey('styleCursor'), isFalse);
    expect(row1['cacheRev'], restored.debugCacheRevision);
    expect(await _count(db, 'srs_cards_cache'), cards);
    expect(await _count(db, 'srs_notes_cache'), notes);
    expect(await restored.changeFingerprint(), startsWith('$epoch1:'));

    // 再开一次：行已经在了——不再重建、纪元不变（以前恢复后到第一条写命令之前，每次开库都整份重建、每次都换纪元）。
    f.store.core.debugExecRaw('DELETE FROM srs_notes_cache');
    final SrsDbStore again = await open();
    expect((await _rowOf(db))!['epoch'], epoch1);
    expect(await again.changeFingerprint(), await restored.changeFingerprint());
    expect(await _count(db, 'srs_notes_cache'), 0, reason: '没有再重建');
    // ignore: avoid_print
    print(
      'WRITE_COST open: restored core=${restored.debugCoreCommands} '
      'again core=${again.debugCoreCommands}',
    );
    expect(again.debugCoreCommands, restored.debugCoreCommands - 2);
  });

  test('老版本存的行没有纪元：开库补上并落盘，修订号与别的键原样', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore s = await _open(storage);
    await s.createDeck('甲');
    final int revision = s.revision;
    expect(revision, greaterThan(0));
    storage.core.debugExecRaw(
      r"UPDATE srs_local_state SET json = json_remove(json, '$.epoch')",
    );
    final SrsDbStore a = await _open(storage);
    final Map<String, Object?> row = (await _row(storage))!;
    expect(row['epoch'], isA<String>());
    expect(row['revision'], revision);
    expect(a.revision, revision);
    expect(await a.changeFingerprint(), '${row['epoch']}:$revision');
    final SrsDbStore b = await _open(storage);
    expect(await b.changeFingerprint(), await a.changeFingerprint());
  });

  test('两个副本对象交替写同一个 profile：修订号从库里的值推进，不回退', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore a = await _open(storage);
    final SrsDbStore b = await _open(storage);
    final int r0 = a.revision;
    expect(b.revision, r0);
    await a.createDeck('甲');
    final int r1 = a.revision;
    expect(r1, greaterThan(r0));
    // b 的内存还停在 r0：以前它把内存里的整行交给内核，库里的修订号被写回 r0 + 这一次的增量。
    await b.createDeck('乙');
    final int r2 = b.revision;
    expect(r2, greaterThan(r1));
    expect((await _row(storage))!['revision'], r2);
    await a.createDeck('丙');
    expect(a.revision, greaterThan(r2));
    expect((await _row(storage))!['revision'], a.revision);
    expect(
      await a.changeFingerprint(),
      startsWith('${(await _row(storage))!['epoch']}:'),
    );
  });

  test('没校过时的副本对象写入不抹掉另一个对象写下的校时状态', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore a = await _open(storage, clock: _clock('boot-a'));
    // b 在 a 校时之前打开：它的时钟既没校过、也没有接上的偏移。
    final SrsDbStore b = await _open(storage, clock: _clock('boot-b'));
    await a.anchorTime(1700000000000, observedAtBootMs: 20);
    final Object? anchor = (await _row(storage))!['anchor'];
    expect(anchor, isNotNull);
    await b.createDeck('乙');
    expect((await _row(storage))!['anchor'], anchor);
    // 之后打开的副本接上这份校时（同一进程：完整恢复）。
    final SrsTrustedClock c = _clock('boot-a');
    await _open(storage, clock: c);
    expect(c.isAnchored, isTrue);
    expect(c.now().$1, 1700000000030);
  });

  test('重读本机状态只读：行被删掉之后不会被重读建回来', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore s = await _open(storage);
    await s.createDeck('甲');
    final String fingerprint = await s.changeFingerprint();
    storage.core.debugExecRaw('DELETE FROM srs_local_state');
    await s.reloadLocal();
    expect(await _row(storage), isNull);
    // 内存里是一个没落盘的新纪元、修订号从 0 起：指纹照样和删之前不同。
    expect(s.revision, 0);
    expect(await s.changeFingerprint(), isNot(fingerprint));
    // 下一条写命令把行建回来，回包里的纪元就是落盘的那个。
    await s.createDeck('乙');
    final Map<String, Object?> row = (await _row(storage))!;
    expect(await s.changeFingerprint(), '${row['epoch']}:${row['revision']}');
  });

  test('改投影的命令回包缺 localRevision / localEpoch 是契约错误：抛错、不动内存', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore s = await _open(storage);
    final int before = s.revision;
    final String fingerprint = await s.changeFingerprint();
    final Map<String, Object?> projected = <String, Object?>{
      'marks': <String, Object?>{'landed': 3},
      'changed': <Object?>[],
    };
    expect(() => s.debugAbsorbLocalWrite(projected), throwsStateError);
    expect(
      () => s.debugAbsorbLocalWrite(<String, Object?>{
        ...projected,
        'localRevision': before + 3,
      }),
      throwsStateError,
    );
    expect(
      () => s.debugAbsorbLocalWrite(<String, Object?>{
        ...projected,
        'localEpoch': 'e',
      }),
      throwsStateError,
    );
    expect(s.revision, before, reason: 'memory untouched on a contract error');
    expect(await s.changeFingerprint(), fingerprint);
    // 修订号与纪元只认回包里的：Dart 自己不按 marks 加。
    expect(
      s.debugAbsorbLocalWrite(<String, Object?>{
        ...projected,
        'localRevision': before + 7,
        'localEpoch': 'e2',
      }),
      3,
    );
    expect(s.revision, before + 7);
    expect(await s.changeFingerprint(), 'e2:${before + 7}');
    // 真命令的回包都带这两个键：还原点照常落下，内存与库里的行一致。
    await s.sync2Checkpoint('m', 'manual');
    final Map<String, Object?> row = (await _row(storage))!;
    expect(row['revision'], s.revision);
    expect(await s.changeFingerprint(), '${row['epoch']}:${row['revision']}');
  });
}
