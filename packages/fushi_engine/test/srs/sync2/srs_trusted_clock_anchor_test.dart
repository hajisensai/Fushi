// 反馈（2026-10-31）：系统时间是准的，Fushi 却提示「该设备时钟明显超前」，复习记录写进了 10 分 42 秒后的
// 未来。根因：校时把一轮同步**末尾**写 head 时的服务器时间，配上这一轮**开头**的时钟读数，整轮同步的耗时
// （大库、卡顿时十几分钟）全算成「本机时钟落后」，可信时间超前同样的时长；另外可信时间按 Stopwatch 推算，
// Android 深睡不计时，睡醒后可信时间落后。
//
// 修复：可信时间 = 校时那一刻的服务器时间 + 开机时钟（含睡眠、不受改系统时间影响，native ffsrs_boot_time_ms）
// 之后走过的量；服务器时间与写 head 那次上传同一刻的开机时钟读数配对（SrsSync2Report.serverTimeBootMs）。
// 中间一度改成「墙钟 + 偏移」（PR #2711）：校时后同一进程里改系统时间，可信时间跟着跳、「系统时间不准」也查不出来，
// 本文件的「改系统时间」用例钉住这条。
//
// 反馈 P9zrTFV5MW（BUG-5264）：一个 profile 的 SRS「今天」一直比系统日期多 1 天、改系统日期也甩不掉，新建的
// profile 正常。根因：跨进程时把「可信时间 − 墙钟」偏移存进本机状态行，下一个进程按「墙钟 + 偏移」估算到下一次
// 校时；用户关了同步、校时状态下把系统时间往回拨过 1 天，偏移就成了 +1 天，之后每个进程都带着。修复：只存
// （服务器时间, 开机时钟读数, 开机时刻），同一次开机里精确接上，换了一次开机或改过系统时间就作废、按墙钟走。
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
      // 持久化的只有校时那一刻的读数与开机时刻，没有「可信时间 − 墙钟」偏移（BUG-5264）。
      expect(c.anchorState, (
        serverTimeMs: 1000000,
        bootTimeMs: 7000,
        bootEpochMs: 1000000 - 7000,
      ));
    });

    test('观测时刻早于校时调用无关：只配服务器时间与同一刻的开机时钟', () {
      final List<int> boot = <int>[5000000];
      final SrsTrustedClock c = SrsTrustedClock(
        wallClockMs: () => boot[0] + 123,
        bootClockMs: () => boot[0],
      );
      // 服务器时间在开机时钟 4000000 时盖下，校时调用发生在 1000 秒后。
      c.anchor(serverTimeMs: 9000000, observedAtBootMs: 4000000);
      expect(c.now().$1, 10000000);
    });

    test('同一次开机的新进程：完整接上服务器时间 + 开机时钟读数，墙钟被 NTP 微调也照样接上', () {
      const int epoch = 1700000000000;
      final List<int> boot = <int>[30000];
      final List<int> drift = <int>[0];
      final SrsTrustedClock c = SrsTrustedClock(
        wallClockMs: () => epoch + boot[0] + drift[0],
        bootClockMs: () => boot[0],
      );
      // 墙钟被校准过 40 秒：仍是同一次开机。
      drift[0] = 40000;
      c.restoreAnchor(
        serverTimeMs: 600000,
        bootTimeMs: 10000,
        bootEpochMs: epoch,
      );
      expect(c.isAnchored, isTrue);
      expect(c.now(), (620000, SrsTimeSource.anchored));
      expect(c.anchorState, (
        serverTimeMs: 600000,
        bootTimeMs: 10000,
        bootEpochMs: epoch,
      ));
    });

    test('重新开机：开机时钟归零、或归零后又走过了读数，都按墙钟走（不带任何偏移），直到下一次校时', () {
      const int oldEpoch = 1700000000000;
      final List<int> wall = <int>[oldEpoch + 90000000 + 3600000];
      final List<int> boot = <int>[500];
      final SrsTrustedClock c = SrsTrustedClock(
        wallClockMs: () => wall[0],
        bootClockMs: () => boot[0],
      );
      // 读数来自重启前（比此刻的开机时钟大）。
      c.restoreAnchor(
        serverTimeMs: oldEpoch + 90000000 + 600000,
        bootTimeMs: 90000000,
        bootEpochMs: oldEpoch,
      );
      expect(c.isAnchored, isFalse);
      expect(c.wallSkewMs, isNull);
      expect(c.now(), (wall[0], SrsTimeSource.wall));
      expect(c.anchorState, isNull);
      // 重启后开了很久，开机时钟又超过了读数：单看读数会误认成同一次开机，开机时刻对不上，照样不认。
      boot[0] = 95000000;
      wall[0] += 95000000;
      c.restoreAnchor(
        serverTimeMs: oldEpoch + 90000000 + 600000,
        bootTimeMs: 90000000,
        bootEpochMs: oldEpoch,
      );
      expect(c.isAnchored, isFalse);
      expect(c.now(), (wall[0], SrsTimeSource.wall));
      // 下一次校时后回到按开机时钟推算。
      c.anchor(serverTimeMs: wall[0] + 100, observedAtBootMs: boot[0]);
      expect(c.now(), (wall[0] + 100, SrsTimeSource.anchored));
      expect(c.wallSkewMs, -100);
    });

    test('认不下的校时状态不抹掉本进程自己的校时', () {
      final List<int> boot = <int>[5000];
      final SrsTrustedClock c = SrsTrustedClock(
        wallClockMs: () => 1700000000000 + boot[0],
        bootClockMs: () => boot[0],
      );
      c.anchor(serverTimeMs: 1700000000000 + 5000, observedAtBootMs: 5000);
      c.restoreAnchor(serverTimeMs: 1, bootTimeMs: 9000000, bootEpochMs: 0);
      expect(c.now(), (1700000000000 + 5000, SrsTimeSource.anchored));
    });

    test('反馈 P9zrTFV5MW：校时后把系统时间拨回 1 天、换进程，再改回来：可信时间不再一直比系统时间多 1 天', () {
      const int day = 24 * 3600 * 1000;
      const int epoch = 1763700000000;
      final List<int> boot = <int>[3600000];
      final List<int> manual = <int>[0];
      int wall() => epoch + boot[0] + manual[0];
      SrsTrustedClock process() =>
          SrsTrustedClock(wallClockMs: wall, bootClockMs: () => boot[0]);

      final SrsTrustedClock first = process();
      first.anchor(serverTimeMs: wall(), observedAtBootMs: boot[0]);
      // 校时之后把系统时间往回拨 1 天：本进程照旧按开机时钟走、报出偏差。
      boot[0] += 60000;
      manual[0] = -day;
      expect(first.now(), (wall() + day, SrsTimeSource.anchored));
      final SrsClockAnchorState saved = first.anchorState!;

      // 换进程（同一次开机）：开机时刻对不上（系统时间被改过），不接校时、按系统时间走——不是「系统时间 + 1 天」。
      boot[0] += 60000;
      final SrsTrustedClock second = process();
      second.restoreAnchor(
        serverTimeMs: saved.serverTimeMs,
        bootTimeMs: saved.bootTimeMs,
        bootEpochMs: saved.bootEpochMs,
      );
      expect(second.now(), (wall(), SrsTimeSource.wall));
      expect(second.anchorState, isNull);

      // 之后随便改系统日期（往前拨 3 天）：「今天」跟着系统日期走，不再固定多 1 天。
      manual[0] = 3 * day;
      expect(second.now(), (wall(), SrsTimeSource.wall));

      // 把系统时间改回准的再开一个进程：同一次开机、开机时刻对得上，精确接上校时。
      manual[0] = 0;
      boot[0] += 60000;
      final SrsTrustedClock third = process();
      third.restoreAnchor(
        serverTimeMs: saved.serverTimeMs,
        bootTimeMs: saved.bootTimeMs,
        bootEpochMs: saved.bootEpochMs,
      );
      expect(third.now(), (wall(), SrsTimeSource.anchored));
      expect(third.wallSkewMs, 0);
    });
  });

  test('本机状态落库：同一次开机的新进程接着按开机时钟算；改过系统时间 / 重新开机后按墙钟走（反馈 P9zrTFV5MW）', () async {
    const int day = 24 * 3600 * 1000;
    final int epoch = DateTime.utc(2026, 11, 21, 6).millisecondsSinceEpoch;
    final List<int> boot = <int>[3600000];
    final List<int> manual = <int>[0];
    int wall() => epoch + boot[0] + manual[0];
    SrsTrustedClock process() =>
        SrsTrustedClock(wallClockMs: wall, bootClockMs: () => boot[0]);
    final SrsStorage st = await openTestSrsStorage();
    Future<SrsDbStore> open(SrsTrustedClock c) => SrsDbStore.open(
      core: st.core,
      profileUid: kProfile,
      deviceId: 'A',
      engine: FfiFsrsEngine.tryCreate(),
      trustedClock: c,
      fallbackRolloverHour: () => 4,
      localOffsetMin: () => 480,
    );
    Future<int> todayOf(SrsDbStore s) async =>
        (await s.dayContext()).dayIndexOf(s.now().$1);
    Future<int> wallDay(SrsDbStore s) async =>
        (await s.dayContext()).dayIndexOf(wall());

    final SrsDbStore first = await open(process());
    // 服务器比墙钟快 7 分钟。
    await first.anchorTime(wall() + 420000, observedAtBootMs: boot[0]);
    // 校时后墙钟被拨回 1 天、又过了 1 分钟：本进程的可信时间不受影响。
    manual[0] = -day;
    boot[0] += 60000;
    final int trusted = first.now().$1;
    expect(trusted - wall(), 420000 + day);
    expect(first.trustedClock.wallSkewMs, -(420000 + day));
    // 本进程再写一条改投影的命令：校时状态随命令落库。
    await first.createDeck('甲');

    // 同一次开机的新进程，系统时间还是拨回过的：不接校时，「今天」= 系统日期，不是系统日期 + 1。
    boot[0] += 1000;
    final SrsDbStore second = await open(process());
    expect(second.trustedClock.isAnchored, isFalse);
    expect(second.now(), (wall(), SrsTimeSource.wall));
    expect(await todayOf(second), await wallDay(second));
    // 这个进程没校过时，写命令不抹掉库里的校时状态。
    await second.createDeck('乙');

    // 系统时间改回准的：同一次开机的新进程精确接上校时（经开机时钟，不经墙钟）。
    manual[0] = 0;
    boot[0] += 1000;
    final SrsDbStore third = await open(process());
    expect(third.trustedClock.isAnchored, isTrue);
    expect(third.now(), (wall() + 420000, SrsTimeSource.anchored));
    expect(await todayOf(third), await wallDay(third));

    // 重新开机：开机时钟从头计，开机时刻也变了。
    final int rebootAt = wall() + 3600000;
    boot[0] = 2000;
    manual[0] = rebootAt - 2000 - epoch;
    final SrsDbStore rebooted = await open(process());
    expect(rebooted.trustedClock.isAnchored, isFalse);
    expect(rebooted.now(), (rebootAt, SrsTimeSource.wall));
  });

  test('慢同步一轮跑了好几分钟：校时后墙钟偏差仍接近 0（以前 = 整轮耗时，误报「时钟超前」、复习写进未来）', () async {
    final List<int> wall = <int>[
      DateTime.utc(2026, 10, 31, 4).millisecondsSinceEpoch,
    ];
    // 开机时钟与墙钟同速，起点不同。
    final SrsTrustedClock clock = SrsTrustedClock(
      wallClockMs: () => wall[0],
      bootClockMs: () => wall[0] - 1700000000000,
    );
    final SrsStorage st = await openTestSrsStorage();
    final SrsDbStore s = await SrsDbStore.open(
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
    );
    final SrsStorage st = await openTestSrsStorage();
    final SrsDbStore s = await SrsDbStore.open(
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
    // 真墙钟 − 真开机时钟在同一次开机里稳定：另一个时钟实例（新进程）认得出是同一次开机，不丢校时。
    c.anchor(serverTimeMs: 1, observedAtBootMs: a);
    final SrsClockAnchorState saved = c.anchorState!;
    final SrsTrustedClock again = srsProcessTrustedClock(st.core);
    again.restoreAnchor(
      serverTimeMs: saved.serverTimeMs,
      bootTimeMs: saved.bootTimeMs,
      bootEpochMs: saved.bootEpochMs,
    );
    expect(again.isAnchored, isTrue);
  });
}
