// 反馈（2026-10-31）：系统时间是准的，Fushi 却提示「该设备时钟明显超前」，复习记录写进了 10 分 42 秒后的
// 未来。根因：校时把一轮同步**末尾**写 head 时的服务器时间，配上这一轮**开头**的时钟读数，整轮同步的耗时
// （大库、卡顿时十几分钟）全算成「本机时钟落后」，可信时间超前同样的时长；另外可信时间按 Stopwatch 推算，
// Android 深睡不计时，睡醒后可信时间落后。修复：可信时间 = 墙钟 + 偏移，偏移由服务器时间与写 head 那次上传
// 同一刻的墙钟配对得出（SrsSync2Report.serverTimeWallMs）。
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
    test('可信时间 = 墙钟 + 校时偏移：睡眠（墙钟跳走）后照样准，不再按单调时钟推算', () {
      final List<int> wall = <int>[1000000];
      final SrsTrustedClock c = SrsTrustedClock(
        wallClockMs: () => wall[0],
        bootId: 'b',
      );
      expect(c.now(), (1000000, SrsTimeSource.wall));
      // 服务器比本机快 5 秒，在墙钟 1000000 那一刻观测到。
      c.anchor(serverTimeMs: 1005000, observedAtWallMs: 1000000);
      expect(c.wallSkewMs, -5000);
      wall[0] += 10 * 3600 * 1000; // 睡了 10 小时：墙钟照走，单调时钟（Android）不走
      expect(c.now(), (wall[0] + 5000, SrsTimeSource.anchored));
    });

    test('观测时刻晚于校时调用无关：偏移只看服务器时间与同一刻的墙钟', () {
      final List<int> wall = <int>[5000000];
      final SrsTrustedClock c = SrsTrustedClock(
        wallClockMs: () => wall[0],
        bootId: 'b',
      );
      // 服务器时间在墙钟 4000000 时盖下（与本机一致），校时调用发生在 1000 秒后。
      c.anchor(serverTimeMs: 4000000, observedAtWallMs: 4000000);
      expect(c.wallSkewMs, 0);
      expect(c.now().$1, wall[0]);
    });

    test('偏移只在写下它的进程里有效', () {
      final SrsTrustedClock c = SrsTrustedClock(
        wallClockMs: () => 0,
        bootId: 'new',
      );
      c.restoreAnchor(offsetMs: 600000, bootId: 'old');
      expect(c.isAnchored, isFalse);
      c.restoreAnchor(offsetMs: 600000, bootId: 'new');
      expect(c.now(), (600000, SrsTimeSource.anchored));
    });
  });

  test('慢同步一轮跑了好几分钟：校时后墙钟偏差仍接近 0（以前 = 整轮耗时，误报「时钟超前」、复习写进未来）', () async {
    final List<int> wall = <int>[
      DateTime.utc(2026, 10, 31, 4).millisecondsSinceEpoch,
    ];
    final SrsTrustedClock clock = SrsTrustedClock(
      wallClockMs: () => wall[0],
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
      wallClockMs: clock.wallNowMs,
    );
    expect(r.error, isNull);
    expect(wall[0] - startedAt, greaterThan(3 * 60 * 1000));
    expect(r.serverTimeMs, isNotNull);
    expect(r.serverTimeWallMs, isNotNull);
    await s.anchorTime(r.serverTimeMs!, observedAtWallMs: r.serverTimeWallMs);
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
      wallClockMs: clock.wallNowMs,
    );
    await s.anchorTime(r.serverTimeMs!, observedAtWallMs: r.serverTimeWallMs);
    expect((clock.wallSkewMs! + skew).abs(), lessThanOrEqualTo(1000));
  });
}
