// 旧库迁移之前那轮只拉不发按进度判（[srsSync2PullBounded] + [SrsPullBound.progress]）：还在收就一直等，连续
// [SrsPullBound.stall] 没有任何进展才放弃，[SrsPullBound.cap] 只防挂死；位置上没有集合时立即做完。
//
// 时钟全是假的（[_FakeTime] 交给 `timer:`），「网络」是按假时钟才返回的读取：不做任何真实等待。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_pull_first.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSync2Result;
import 'package:test/test.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000f1';

/// 可控时钟：[create] 交给被测代码当计时器工厂，[advance] 按到期先后触发。
class _FakeTime {
  Duration now = Duration.zero;
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  Timer create(Duration d, void Function() callback) {
    final _FakeTimer t = _FakeTimer(now + d, callback);
    _timers.add(t);
    return t;
  }

  /// [d] 之后完成的 future（假的网络耗时）。
  Future<void> delay(Duration d) {
    final Completer<void> c = Completer<void>();
    create(d, c.complete);
    return c.future;
  }

  /// 往前走 [d]：到期的计时器按先后触发，每触发一个都先让被测代码把由此引起的异步工作做完。
  Future<void> advance(Duration d) async {
    final Duration end = now + d;
    while (true) {
      await pumpEventQueue();
      final List<_FakeTimer> due =
          _timers.where((_FakeTimer t) => t.isActive && t.at <= end).toList()
            ..sort((_FakeTimer a, _FakeTimer b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      now = due.first.at;
      due.first.fire();
    }
    now = end;
    await pumpEventQueue();
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.at, this._callback);

  final Duration at;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// 内核替身：`plan` 让拉 [files]，收段只计数。
class _Host implements SrsSync2Host {
  _Host(this.files);

  final List<String> files;
  final List<String> ops = <String>[];
  int ingested = 0;

  @override
  String get profileUid => kProfile;

  @override
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) async {
    ops.add(request['op']! as String);
    if (request['op'] == 'plan') {
      return SrsSync2Result(<String, Object?>{
        'fetch': <Object?>[
          <String, Object?>{'files': files},
        ],
      }, const <(String, Uint8List)>[]);
    }
    return const SrsSync2Result(<String, Object?>{}, <(String, Uint8List)>[]);
  }

  @override
  Future<void> sync2IngestBegin() async {}

  @override
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  }) async {
    ingested += segments.length;
    return <String, Object?>{};
  }

  @override
  Future<Map<String, Object?>> sync2IngestFinish() async => <String, Object?>{};

  @override
  Future<void> sync2IngestEnd() async {}
}

/// 位置替身：有 / 没有集合（`meta.json`）；段的读取按 [segmentDelay] 的假耗时返回（null = 永远不返回）。
class _Location implements SrsLocationStore {
  _Location(this.time, {this.hasCollection = true, this.segmentDelay});

  final _FakeTime time;
  final bool hasCollection;
  final Duration? Function(int index)? segmentDelay;
  int _reads = 0;

  @override
  Future<Uint8List?> get(String path) async {
    if (path == 'meta.json') {
      return hasCollection
          ? Uint8List.fromList(utf8.encode('{"minReader":1}'))
          : null;
    }
    final Duration? d = segmentDelay?.call(_reads++);
    if (d == null) return Completer<Uint8List?>().future;
    await time.delay(d);
    return Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5, 6, 7]);
  }

  @override
  Future<List<SrsLocationEntry>> list(String dir) async =>
      const <SrsLocationEntry>[];

  @override
  Future<bool> exists(String path) async => false;

  @override
  Future<void> put(String path, Uint8List bytes) =>
      throw StateError('pull-only must not write');

  @override
  Future<void> putNew(String path, Uint8List bytes) =>
      throw StateError('pull-only must not write');

  @override
  Future<void> delete(String path) =>
      throw StateError('pull-only must not delete');
}

const SrsPullBound kMigrate = SrsPullBound.progress(
  stall: kSrsPullBeforeMigrateStall,
  cap: kSrsPullBeforeMigrateCap,
);

/// 跑一次迁移前的拉取（与调度器 `pullInto` 同一接法：位置读取与内核调用都算进展）。
({Future<SrsPullOutcome> outcome, List<Object> errors}) _pull(
  _FakeTime time,
  _Host host,
  _Location location, {
  SrsPullBound bound = kMigrate,
}) {
  final List<Object> errors = <Object>[];
  final Future<SrsPullOutcome> outcome = srsSync2PullBounded(
    host,
    (SrsSync2Host gated, void Function() activity) async {
      await srsSync2PullOnly(
        host: gated,
        location: location,
        locationId: 'loc',
        nowMs: () => 0,
        fetchConcurrency: 1,
        onActivity: activity,
      );
    },
    bound: bound,
    onError: (Object e, StackTrace _) => errors.add(e),
    timer: time.create,
  );
  return (outcome: outcome, errors: errors);
}

/// 一直走假时钟直到 [f] 做完（上限 [limit] 防测试本身挂住），交回结果与做完时的假时刻。
Future<(SrsPullOutcome, Duration)> _runUntilDone(
  _FakeTime time,
  Future<SrsPullOutcome> f, {
  Duration step = const Duration(seconds: 1),
  Duration limit = const Duration(hours: 2),
}) async {
  SrsPullOutcome? got;
  Duration? at;
  unawaited(
    f.then((SrsPullOutcome o) {
      got = o;
      at = time.now;
    }),
  );
  while (got == null && time.now < limit) {
    await time.advance(step);
  }
  expect(got, isNotNull, reason: 'pull did not finish within $limit');
  return (got!, at!);
}

void main() {
  test('取值：停滞判定不比旧的整段预算长，总上限远大于实测最慢的收齐耗时（413 s）', () {
    expect(kSrsPullBeforeMigrateStall, const Duration(minutes: 2));
    expect(
      kSrsPullBeforeMigrateCap,
      greaterThan(const Duration(seconds: 413 * 4)),
    );
  });

  test('一直有进展、总时长远超旧的 2 分钟预算：等到收齐，不提前放弃', () async {
    final _FakeTime time = _FakeTime();
    // 12 个段，每个读 90 秒（比停滞判定短）：一共 18 分钟。
    final _Host host = _Host(<String>[
      for (int i = 0; i < 12; i++) 'devices/d1/s$i',
    ]);
    final ({Future<SrsPullOutcome> outcome, List<Object> errors}) run = _pull(
      time,
      host,
      _Location(
        time,
        segmentDelay: (int i) => i < 12 ? const Duration(seconds: 90) : null,
      ),
    );
    final (SrsPullOutcome outcome, Duration at) = await _runUntilDone(
      time,
      run.outcome,
    );
    expect(outcome, SrsPullOutcome.done);
    expect(at, const Duration(seconds: 12 * 90));
    expect(at, greaterThan(const Duration(minutes: 2)));
    expect(host.ingested, 12, reason: 'every segment was ingested');
    expect(run.errors, isEmpty);
  });

  test('对照：同样的传输按旧的固定 2 分钟预算会在 120 秒时放弃', () async {
    final _FakeTime time = _FakeTime();
    final _Host host = _Host(<String>[
      for (int i = 0; i < 12; i++) 'devices/d1/s$i',
    ]);
    final ({Future<SrsPullOutcome> outcome, List<Object> errors}) run = _pull(
      time,
      host,
      _Location(time, segmentDelay: (int _) => const Duration(seconds: 90)),
      bound: const SrsPullBound.budget(Duration(minutes: 2)),
    );
    final (SrsPullOutcome outcome, Duration at) = await _runUntilDone(
      time,
      run.outcome,
    );
    expect(outcome, SrsPullOutcome.capped);
    expect(at, const Duration(minutes: 2));
    expect(host.ingested, 0);
  });

  test('停滞：最后一次进展之后整整 stall 才放弃（差一秒都不放弃），闸门关上后迟到的结果碰不到本机', () async {
    // 前 3 个段各 90 秒读完（最后一次进展在 270 秒），第 4 个永远不返回。
    const Duration lastProgress = Duration(seconds: 3 * 90);
    final _FakeTime time2 = _FakeTime();
    final _Host host2 = _Host(<String>[
      for (int i = 0; i < 6; i++) 'devices/d1/s$i',
    ]);
    final ({Future<SrsPullOutcome> outcome, List<Object> errors}) run2 = _pull(
      time2,
      host2,
      _Location(
        time2,
        segmentDelay: (int i) => i < 3 ? const Duration(seconds: 90) : null,
      ),
    );
    SrsPullOutcome? got2;
    unawaited(run2.outcome.then((SrsPullOutcome o) => got2 = o));
    await time2.advance(
      lastProgress + kSrsPullBeforeMigrateStall - const Duration(seconds: 1),
    );
    expect(got2, isNull, reason: 'one second before the stall: still waiting');
    await time2.advance(const Duration(seconds: 1));
    expect(got2, SrsPullOutcome.stalled);
    expect(host2.ingested, 0, reason: 'the batch never completed');
    expect(run2.errors, isEmpty);
  });

  test('一直有进展但永远收不完：到总上限放弃', () async {
    final _FakeTime time = _FakeTime();
    final _Host host = _Host(<String>[
      for (int i = 0; i < 10000; i++) 'devices/d1/s$i',
    ]);
    final ({Future<SrsPullOutcome> outcome, List<Object> errors}) run = _pull(
      time,
      host,
      _Location(time, segmentDelay: (int _) => const Duration(seconds: 60)),
    );
    final (SrsPullOutcome outcome, Duration at) = await _runUntilDone(
      time,
      run.outcome,
      step: const Duration(seconds: 30),
    );
    expect(outcome, SrsPullOutcome.capped);
    expect(at, kSrsPullBeforeMigrateCap);
  });

  test('位置上没有集合：立即做完，一个计时器都没到点', () async {
    final _FakeTime time = _FakeTime();
    final _Host host = _Host(const <String>[]);
    final ({Future<SrsPullOutcome> outcome, List<Object> errors}) run = _pull(
      time,
      host,
      _Location(time, hasCollection: false),
    );
    await pumpEventQueue();
    SrsPullOutcome? got;
    unawaited(run.outcome.then((SrsPullOutcome o) => got = o));
    await pumpEventQueue();
    expect(got, SrsPullOutcome.done);
    expect(time.now, Duration.zero);
    expect(host.ops, <String>['identity'], reason: 'nothing planned or pulled');
  });

  test('读取出错不算进展', () async {
    int marks = 0;
    final SrsActivityLocationStore store = SrsActivityLocationStore(
      _Failing(),
      () => marks++,
    );
    await expectLater(store.get('x'), throwsStateError);
    await expectLater(store.list('x'), throwsStateError);
    expect(marks, 0);
  });
}

class _Failing implements SrsLocationStore {
  @override
  Future<Uint8List?> get(String path) async => throw StateError('offline');

  @override
  Future<List<SrsLocationEntry>> list(String dir) async =>
      throw StateError('offline');

  @override
  Future<bool> exists(String path) async => throw StateError('offline');

  @override
  Future<void> put(String path, Uint8List bytes) async {}

  @override
  Future<void> putNew(String path, Uint8List bytes) async {}

  @override
  Future<void> delete(String path) async {}
}
