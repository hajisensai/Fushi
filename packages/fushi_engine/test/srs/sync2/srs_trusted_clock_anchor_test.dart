// 反馈（2026-10-31）：系统时间是准的，Fushi 却提示「该设备时钟明显超前」，复习记录写进了 10 分 42 秒后的
// 未来。根因：校时把一轮同步**末尾**写 head 时的服务器时间，配上这一轮**开头**的时钟读数，整轮同步的耗时
// （大库、卡顿时十几分钟）全算成「本机时钟落后」，可信时间超前同样的时长；另外可信时间按 Stopwatch 推算，
// Android 深睡不计时，睡醒后可信时间落后。
//
// 修复：可信时间 = 校时那一刻的服务器时间 + 开机时钟（含睡眠、不受改系统时间影响，native ffsrs_boot_time_ms）
// 之后走过的量；服务器时间与写 head 那次上传同一刻的开机时钟读数配对（SrsSync2Report.serverTimeBootMs）。
// 中间一度改成「墙钟 + 偏移」（PR #2711）：校时后同一进程里改系统时间，可信时间跟着跳、「系统时间不准」也查不出来，
// 本文件的「改系统时间」用例钉住这条。
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000ee';

/// 慢后端：服务器按自己的时钟（[serverSkewMs] = 服务器 − 本机墙钟）给文件盖 mtime；每次列目录 / 读写都让
/// 本机墙钟走 [stepMs]（模拟大库 + 卡顿下一轮同步跑很久）。
class _SlowServerStore extends SrsMemoryLocationStore {
  _SlowServerStore(this.wall, {required this.stepMs, this.serverSkewMs = 0});

  final List<int> wall;
  final int stepMs;
  final int serverSkewMs;
  final Map<String, int> mtimes = <String, int>{};

  int get _server => wall[0] + serverSkewMs;

  @override
  Future<List<SrsLocationEntry>> list(String dir) async {
    wall[0] += stepMs;
    final String prefix = dir.isEmpty ? '' : '$dir/';
    return <SrsLocationEntry>[
      for (final SrsLocationEntry e in await super.list(dir))
        SrsLocationEntry(
          e.name,
          isFolder: e.isFolder,
          size: e.size,
          modifiedAt: mtimes['$prefix${e.name}'],
        ),
    ];
  }

  @override
  Future<Uint8List?> get(String path) async {
    wall[0] += stepMs;
    return super.get(path);
  }

  @override
  Future<void> put(String path, Uint8List bytes) async {
    wall[0] += stepMs;
    mtimes[path] = _server;
    await super.put(path, bytes);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('SrsTrustedClock', () {
    test('深睡：开机时钟照走（Stopwatch / CLOCK_MONOTONIC 停了也无关），可信时间不落后', () {
      // 墙钟与开机时钟各走各的：只有开机时钟进可信时间。
      final List<int> wall = <int>[1000000];
      final List<int> boot = <int>[50000];
      final SrsTrustedClock c = SrsTrustedClock(
        wallClockMs: () => wall[0],
        bootClockMs: () => boot[0],
        bootId: 'b',
      );
      expect(c.now(), (1000000, SrsTimeSource.wall));
      // 服务器比本机墙钟快 5 秒，在开机时钟 50000 那一刻观测到。
      c.anchor(serverTimeMs: 1005000, observedAtBootMs: 50000);
      expect(c.wallSkewMs, -5000);
      // 睡了 10 小时：墙钟、开机时钟都走；单调时钟（Android CLOCK_MONOTONIC / Dart Stopwatch）不走，不参与。
      const int sleep = 10 * 3600 * 1000;
      wall[0] += sleep;
      boot[0] += sleep;
      expect(c.now(), (1005000 + sleep, SrsTimeSource.anchored));
      expect(c.wallSkewMs, -5000);
    });

    test('校时后改系统时间：可信时间不跟着跳，wallSkewMs 现算报出来', () {
      final List<int> wall = <int>[1000000];
      final List<int> boot = <int>[7000];
      final SrsTrustedClock c = SrsTrustedClock(
        wallClockMs: () => wall[0],
        bootClockMs: () => boot[0],
        bootId: 'b',
      );
      c.anchor(serverTimeMs: 1000000, observedAtBootMs: 7000);
      expect(c.wallSkewMs, 0);
      wall[0] += 60000;
      boot[0] += 60000;
      expect(c.now(), (1060000, SrsTimeSource.anchored));
      // 用户把系统时间往后拨 2 小时：可信时间照旧，偏差如实报 +2 小时。
      wall[0] += 2 * 3600 * 1000;
      expect(c.now(), (1060000, SrsTimeSource.anchored));
      expect(c.wallSkewMs, 2 * 3600 * 1000);
      // 再拨到比真实时间早 1 天，又过 1 秒：同样。
      wall[0] = 1060000 - 24 * 3600 * 1000;
      boot[0] += 1000;
      expect(c.now(), (1061000, SrsTimeSource.anchored));
      expect(c.wallSkewMs, -24 * 3600 * 1000 - 1000);
      // 持久化下来的偏移是「可信时间 − 当前墙钟」，供下一个进程估算。
      expect(c.anchorState?.offsetMs, 24 * 3600 * 1000 + 1000);
    });

    test('观测时刻早于校时调用无关：只配服务器时间与同一刻的开机时钟', () {
      final List<int> boot = <int>[5000000];
      final SrsTrustedClock c = SrsTrustedClock(
        wallClockMs: () => boot[0] + 123,
        bootClockMs: () => boot[0],
        bootId: 'b',
      );
      // 服务器时间在开机时钟 4000000 时盖下，校时调用发生在 1000 秒后。
      c.anchor(serverTimeMs: 9000000, observedAtBootMs: 4000000);
      expect(c.now().$1, 10000000);
    });

    test('同一进程恢复：完整接上服务器时间 + 开机时钟读数', () {
      final List<int> boot = <int>[30000];
      final SrsTrustedClock c = SrsTrustedClock(
        wallClockMs: () => 0,
        bootClockMs: () => boot[0],
        bootId: 'p1',
      );
      c.restoreAnchor(
        offsetMs: 999,
        bootId: 'p1',
        serverTimeMs: 600000,
        bootTimeMs: 10000,
      );
      expect(c.isAnchored, isTrue);
      expect(c.now(), (620000, SrsTimeSource.anchored));
    });

    test('重启（别的进程 / 开机时钟归零）：退回墙钟 + 上次偏移，标未校时，直到下一次校时', () {
      final List<int> wall = <int>[2000000];
      final List<int> boot = <int>[500];
      final SrsTrustedClock other = SrsTrustedClock(
        wallClockMs: () => wall[0],
        bootClockMs: () => boot[0],
        bootId: 'new',
      );
      other.restoreAnchor(
        offsetMs: 600000,
        bootId: 'old',
        serverTimeMs: 1000000,
        bootTimeMs: 90000000,
      );
      expect(other.isAnchored, isFalse);
      expect(other.wallSkewMs, isNull);
      expect(other.now(), (2600000, SrsTimeSource.wall));
      // 偏移继续往下传（再重启一次照样用），但不带开机时钟读数。
      expect(other.anchorState, (
        bootId: 'new',
        offsetMs: 600000,
        serverTimeMs: null,
        bootTimeMs: null,
      ));
      // 同一个 bootId、开机时钟却比读数小（读数来自重启前）：同样不认读数。
      final SrsTrustedClock same = SrsTrustedClock(
        wallClockMs: () => wall[0],
        bootClockMs: () => boot[0],
        bootId: 'old',
      );
      same.restoreAnchor(
        offsetMs: 600000,
        bootId: 'old',
        serverTimeMs: 1000000,
        bootTimeMs: 90000000,
      );
      expect(same.isAnchored, isFalse);
      expect(same.now(), (2600000, SrsTimeSource.wall));
      // 下一次校时后回到按开机时钟推算。
      other.anchor(serverTimeMs: 2000100, observedAtBootMs: 500);
      expect(other.now(), (2000100, SrsTimeSource.anchored));
      expect(other.wallSkewMs, -100);
    });
  });

  test('本机状态落库：同一进程重开副本接着按开机时钟算；重新开机后退回墙钟 + 偏移', () async {
    final List<int> wall = <int>[
      DateTime.utc(2026, 10, 31, 4).millisecondsSinceEpoch,
    ];
    final List<int> boot = <int>[3600000];
    SrsTrustedClock clockFor(String bootId) => SrsTrustedClock(
      wallClockMs: () => wall[0],
      bootClockMs: () => boot[0],
      bootId: bootId,
    );
    final SrsStorage st = await openTestSrsStorage();
    Future<SrsDbStore> open(SrsTrustedClock c) => SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: 'A',
      engine: FfiFsrsEngine.tryCreate(),
      trustedClock: c,
    );
    final SrsDbStore first = await open(clockFor('p1'));
    // 服务器比墙钟快 7 分钟。
    await first.anchorTime(wall[0] + 420000, observedAtBootMs: boot[0]);
    // 校时后墙钟被拨慢 1 小时、又过了 1 分钟：可信时间不受影响。
    wall[0] += 60000 - 3600000;
    boot[0] += 60000;
    final int trusted = first.now().$1;
    expect(trusted - wall[0], 420000 + 3600000);
    expect(first.trustedClock.wallSkewMs, -(420000 + 3600000));
    // 用同一刻的读数再校一次（服务器时间不变）：落库最新的偏移。
    await first.anchorTime(trusted, observedAtBootMs: boot[0]);

    final SrsDbStore sameProcess = await open(clockFor('p1'));
    expect(sameProcess.now(), (trusted, SrsTimeSource.anchored));
    boot[0] += 1000;
    wall[0] += 1000;
    expect(sameProcess.now(), (trusted + 1000, SrsTimeSource.anchored));

    // 重新开机：开机时钟从头计，进程身份也换了。
    boot[0] = 2000;
    final SrsDbStore rebooted = await open(clockFor('p2'));
    expect(rebooted.trustedClock.isAnchored, isFalse);
    expect(rebooted.now(), (trusted + 1000, SrsTimeSource.wall));
  });

  test('慢同步一轮跑了好几分钟：校时后墙钟偏差仍接近 0（以前 = 整轮耗时，误报「时钟超前」、复习写进未来）', () async {
    final List<int> wall = <int>[
      DateTime.utc(2026, 10, 31, 4).millisecondsSinceEpoch,
    ];
    // 开机时钟与墙钟同速，起点不同。
    final SrsTrustedClock clock = SrsTrustedClock(
      wallClockMs: () => wall[0],
      bootClockMs: () => wall[0] - 1700000000000,
      bootId: 'boot',
    );
    final SrsStorage st = await openTestSrsStorage();
    final SrsDbStore s = await SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: 'A',
      engine: FfiFsrsEngine.tryCreate(),
      trustedClock: clock,
    );
    await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '雨',
      },
    );
    // 每次后端调用 30 秒：这一轮总共跑好几分钟。
    final _SlowServerStore loc = _SlowServerStore(wall, stepMs: 30000);
    final int startedAt = wall[0];
    final SrsSync2Report r = await srsSync2Round(
      host: s,
      location: loc,
      locationId: 'loc',
      nowMs: () => s.now().$1,
      bootClockMs: clock.bootNowMs,
    );
    expect(r.error, isNull);
    expect(wall[0] - startedAt, greaterThan(3 * 60 * 1000));
    expect(r.serverTimeMs, isNotNull);
    expect(r.serverTimeBootMs, isNotNull);
    await s.anchorTime(r.serverTimeMs!, observedAtBootMs: r.serverTimeBootMs!);
    // 服务器与本机时钟一致：偏差只剩写 head 那一次上传耗时的一半。
    expect(clock.wallSkewMs!.abs(), lessThanOrEqualTo(30000 ~/ 2));
    expect((s.now().$1 - wall[0]).abs(), lessThanOrEqualTo(30000 ~/ 2));
  });

  test('本机墙钟真的慢 11 分钟：校时把复习时间纠到服务器时间', () async {
    final List<int> wall = <int>[
      DateTime.utc(2026, 10, 31, 4).millisecondsSinceEpoch,
    ];
    final SrsTrustedClock clock = SrsTrustedClock(
      wallClockMs: () => wall[0],
      bootClockMs: () => wall[0] - 1700000000000,
      bootId: 'boot',
    );
    final SrsStorage st = await openTestSrsStorage();
    final SrsDbStore s = await SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: 'A',
      engine: FfiFsrsEngine.tryCreate(),
      trustedClock: clock,
    );
    await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '風',
      },
    );
    const int skew = 11 * 60 * 1000;
    final _SlowServerStore loc = _SlowServerStore(
      wall,
      stepMs: 1000,
      serverSkewMs: skew,
    );
    final SrsSync2Report r = await srsSync2Round(
      host: s,
      location: loc,
      locationId: 'loc',
      nowMs: () => s.now().$1,
      bootClockMs: clock.bootNowMs,
    );
    await s.anchorTime(r.serverTimeMs!, observedAtBootMs: r.serverTimeBootMs!);
    expect((clock.wallSkewMs! + skew).abs(), lessThanOrEqualTo(1000));
  });

  test('生产时钟：开机时钟取自原生库（缺库 / 缺符号直接失败，不退回别的时钟）', () async {
    final SrsStorage st = await openTestSrsStorage();
    final SrsTrustedClock c = srsProcessTrustedClock(st.core);
    final int a = c.bootNowMs();
    expect(a, greaterThan(0));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    // Windows GetTickCount64 分辨率约 16 ms。
    expect(c.bootNowMs() - a, inInclusiveRange(40, 5000));
    // 同一进程两次取到的身份相同：重开副本不丢校时。
    c.anchor(serverTimeMs: 1, observedAtBootMs: a);
    final SrsClockAnchorState saved = c.anchorState!;
    final SrsTrustedClock again = srsProcessTrustedClock(st.core);
    again.restoreAnchor(
      offsetMs: saved.offsetMs,
      bootId: saved.bootId,
      serverTimeMs: saved.serverTimeMs,
      bootTimeMs: saved.bootTimeMs,
    );
    expect(again.isAnchored, isTrue);
  });
}
