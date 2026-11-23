// 本机状态（修订号 / 纪元 / 校时 / 待回收媒体）只由内核写，Dart 不整份重写、命令也不带整份；修订号与纪元由内核持有并在
// 回包里带回，校时状态随命令或经 `local_anchor` 交给内核。这里经公开命令与另开的副本对象钉住：
//
// - 校时、待回收集合各管各的，互不抹掉；校时是一条内核命令、不发读命令；
// - 指向同一个 profile 的两个副本对象交替写：修订号从库里的值推进，不回退；没校过时的那个不抹掉另一个写下的校时状态；
// - 改投影的命令回包缺 `localRevision` / `localEpoch` 是契约错误。
//
// 新代：协议 3 的本机状态行 `srs_local_state.json`（native/fushi_fsrs/src/store/local_state.rs）不存在了，这里不再
// 直接读写那张表。删掉的协议 3 用例：「老行没纪元开库补上」「重读不把删掉的行建回来」（都要手改那一行，新代没有那一行，
// 旧库只经换代迁移进来）、「覆盖恢复后缓存只重建一次、行在重建之后落下」（协议 3 的恢复清空本机状态行与缓存表、靠
// `cacheRev` 判重建；新代派生层是真相的纯函数，恢复走 [SrsDbStore.afterRestore] = 整层重建，备份恢复归 G11-4）、
// 「多出一个不认识的键 / cacheRev 原样留着」（行内键名是协议 3 的存储细节）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_reads.dart';

const String kUid = '01928c3e-0000-7000-8000-00000000d7a5';

/// 墙钟 1000、开机时钟 [boot]（可调，缺省 50）的时钟：开机时刻恒定，同一次开机。
SrsTrustedClock _clock({int Function()? boot}) =>
    SrsTrustedClock(wallClockMs: () => 1000, bootClockMs: boot ?? () => 50);

Future<SrsDbStore> _open(SrsStorage storage, {SrsTrustedClock? clock}) =>
    SrsDbStore.open(
      core: storage.core,
      profileUid: kUid,
      deviceId: 'dev',
      engine: const FakeFsrsEngine(),
      trustedClock: clock,
      fallbackRolloverHour: () => 4,
    );

/// 库里落下的本机状态：另开一个副本对象读到的修订号与变化指纹（`纪元:修订号`）。
Future<(int, String)> _persisted(SrsStorage storage) async {
  final SrsDbStore fresh = await _open(storage);
  return (fresh.revision, await fresh.changeFingerprint());
}

String _epochOf(String fingerprint) =>
    fingerprint.substring(0, fingerprint.lastIndexOf(':'));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('校时、待回收集合各管各的，互不抹掉；校时是一条内核命令、不发读命令', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore s = await _open(storage, clock: _clock());
    final String opened = await s.changeFingerprint();

    final int commands = s.debugCoreCommands;
    srsDebugReadCommands = 0;
    await s.anchorTime(1700000000000, observedAtBootMs: 20);
    // ignore: avoid_print
    print(
      'WRITE_COST anchorTime: reads=$srsDebugReadCommands '
      'core=${s.debugCoreCommands - commands}',
    );
    expect(srsDebugReadCommands, 0);
    expect(s.debugCoreCommands - commands, 1);
    // 之后打开的同进程副本接上这份校时：可信时间 = 1700000000000 + (50 − 20)。
    final SrsTrustedClock c1 = _clock();
    await _open(storage, clock: c1);
    expect(c1.isAnchored, isTrue);
    expect(c1.now().$1, 1700000000030);

    expect(await s.queueMediaGc(<String>['a.png']), <String>{'a.png'});
    await s.anchorTime(1700000001000, observedAtBootMs: 30);
    await s.sync2Checkpoint('m', 'manual');
    // 校时没抹掉待回收集合，待回收集合也没抹掉校时。
    expect(await s.pendingMediaGc(), <String>{'a.png'});
    expect(await (await _open(storage)).pendingMediaGc(), <String>{'a.png'});
    final SrsTrustedClock c2 = _clock();
    await _open(storage, clock: c2);
    expect(c2.now().$1, 1700000001020);
    // 纪元没换，修订号与库里一致。
    final (int revision, String fingerprint) = await _persisted(storage);
    expect(_epochOf(fingerprint), _epochOf(opened));
    expect(revision, s.revision);
    expect(await s.changeFingerprint(), fingerprint);
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
    expect((await _persisted(storage)).$1, r2);
    await a.createDeck('丙');
    expect(a.revision, greaterThan(r2));
    final (int revision, String fingerprint) = await _persisted(storage);
    expect(revision, a.revision);
    expect(await a.changeFingerprint(), fingerprint);
  });

  test('没校过时的副本对象写入不抹掉另一个对象写下的校时状态', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore a = await _open(storage, clock: _clock());
    // b 在 a 校时之前打开：它的时钟既没校过、也没有接上的偏移。
    final SrsDbStore b = await _open(storage, clock: _clock());
    await a.anchorTime(1700000000000, observedAtBootMs: 20);
    await b.createDeck('乙');
    // 之后打开的副本接上这份校时（同一进程：完整恢复）。
    final SrsTrustedClock c = _clock();
    await _open(storage, clock: c);
    expect(c.isAnchored, isTrue);
    expect(c.now().$1, 1700000000030);
  });

  test('改投影的命令回包缺 localRevision / localEpoch 是契约错误：抛错、不动内存', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore s = await _open(storage);
    final int before = s.revision;
    final String fingerprint = await s.changeFingerprint();
    // 新代写命令回包：`changed`（[种类, 规范实体 ID]）/ `purged` / `replayed`，碰过的实体数是三者之和。
    final Map<String, Object?> projected = <String, Object?>{
      'changed': <Object?>[
        <Object?>['card', '01928c3e-0000-7000-8000-0000000000c1'],
        <Object?>['card', '01928c3e-0000-7000-8000-0000000000c2'],
      ],
      'replayed': <Object?>['01928c3e-0000-7000-8000-0000000000c3'],
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
    // 修订号与纪元只认回包里的：Dart 自己不按碰过的实体数加。
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
    // 真命令的回包都带这两个键：还原点照常落下，内存与库里的一致。
    await s.sync2Checkpoint('m', 'manual');
    expect(await s.changeFingerprint(), (await _persisted(storage)).$2);
  });
}
