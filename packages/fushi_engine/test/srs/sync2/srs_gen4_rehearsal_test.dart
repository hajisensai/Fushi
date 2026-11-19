// 存储换代预演（设计 §8 G4b）：空闲调度每个 app 版本只跑出一次结论、没跑完的下次再试、命令报错本进程不再试、
// 停下时把取消交给内核；真内核上对 app 自己的库跑一次，缓存配置按库里的 profile 由 Dart 给全，报告读得回来。
import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_gen4_rehearsal.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000e9';

SrsGen4RehearsalReport _report(String verdict, String? version) =>
    SrsGen4RehearsalReport.fromJson(<String, Object?>{
      'verdict': verdict,
      if (version != null) 'appVersion': version,
      'finishedAtMs': 1,
    });

/// 按内核的契约做的假执行端：[run] 先过一段「登记之前」的窗口（真内核里是读缓存配置、起后台 isolate），然后登记
/// 这一次的运行号；取消只停登记着的那一次，登记之前到的按运行号记下、那一次一登记就停（不是黏性的「取消过就算」）。
class _FakeRunner implements SrsGen4RehearsalRunner {
  _FakeRunner({this.last, this.verdict = 'pass'});

  SrsGen4RehearsalReport? last;
  String verdict;
  Object? error;

  /// 登记之后的那一整轮：停下（或放行）前一直挂着。
  Completer<void>? gate;

  /// 登记之前的窗口。
  Completer<void>? beforeRegistration;

  /// 读上一份报告的窗口。
  Completer<void>? lastReportGate;
  int lastReads = 0;
  int runs = 0;
  int cancels = 0;
  String? _registered;
  bool _stopped = false;
  final Set<String> _cancelledEarly = <String>{};

  @override
  Future<SrsGen4RehearsalReport?> lastReport() async {
    lastReads++;
    if (lastReportGate case final Completer<void> g) await g.future;
    return last;
  }

  @override
  Future<SrsGen4RehearsalReport> run(
    String appVersion, {
    required String runId,
  }) async {
    runs++;
    if (beforeRegistration case final Completer<void> g) await g.future;
    _stopped = _cancelledEarly.contains(runId);
    _cancelledEarly.clear();
    _registered = runId;
    try {
      if (!_stopped) {
        if (gate case final Completer<void> g) await g.future;
      }
      if (error case final Object e) throw e;
      final SrsGen4RehearsalReport r = _report(
        _stopped ? 'cancelled' : verdict,
        appVersion,
      );
      last = r;
      return r;
    } finally {
      _registered = null;
    }
  }

  @override
  void cancel(String runId) {
    cancels++;
    if (_registered == runId) {
      _stopped = true;
      if (gate case final Completer<void> g when !g.isCompleted) g.complete();
    } else {
      _cancelledEarly.add(runId);
    }
  }
}

SrsGen4RehearsalScheduler _scheduler(
  _FakeRunner runner, {
  String version = '1.0+1',
  bool Function()? idle,
  List<Object>? errors,
}) => SrsGen4RehearsalScheduler(
  readRunner: () async => runner,
  appVersion: () => version,
  canRunNow: idle ?? () => true,
  onError: (Object e, StackTrace _) => errors?.add(e),
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('the background rehearsal auto-runs on desktop only', () {
    for (final String os in <String>['windows', 'macos', 'linux']) {
      expect(srsGen4RehearsalAutoRunsOn(os), isTrue, reason: os);
    }
    for (final String os in <String>['android', 'ios', 'fuchsia']) {
      expect(srsGen4RehearsalAutoRunsOn(os), isFalse, reason: os);
    }
  });

  group('scheduler', () {
    test(
      'runs once per app version and stops after a settled verdict',
      () async {
        final _FakeRunner runner = _FakeRunner();
        final SrsGen4RehearsalScheduler s = _scheduler(runner);
        final SrsGen4RehearsalReport? r = await s.maybeRun();
        expect(r?.verdict, SrsGen4RehearsalVerdict.pass);
        expect(r?.appVersion, '1.0+1');
        expect(await s.maybeRun(), isNull);
        expect(runner.runs, 1);
        // 新进程、同一版本：上一份报告就是本版本的结论，不再跑。
        final SrsGen4RehearsalScheduler again = _scheduler(runner);
        expect(await again.maybeRun(), isNull);
        expect(runner.runs, 1);
        // 换了版本：再跑一次。
        final SrsGen4RehearsalScheduler next = _scheduler(
          runner,
          version: '1.1+2',
        );
        expect((await next.maybeRun())?.verdict, SrsGen4RehearsalVerdict.pass);
        expect(runner.runs, 2);
      },
    );

    test('a failing library is a settled verdict too', () async {
      final _FakeRunner runner = _FakeRunner(verdict: 'fail');
      final SrsGen4RehearsalScheduler s = _scheduler(runner);
      expect((await s.maybeRun())?.verdict, SrsGen4RehearsalVerdict.fail);
      expect(await s.maybeRun(), isNull);
      expect(runner.runs, 1);
    });

    test(
      'an incomplete comparison is a settled verdict and not re-run',
      () async {
        final _FakeRunner runner = _FakeRunner(verdict: 'incomplete');
        final SrsGen4RehearsalScheduler s = _scheduler(runner);
        expect(
          (await s.maybeRun())?.verdict,
          SrsGen4RehearsalVerdict.incomplete,
        );
        expect(await s.maybeRun(), isNull);
        expect(await _scheduler(runner).maybeRun(), isNull);
        expect(runner.runs, 1);
      },
    );

    test('an error verdict is settled: this version does not re-run', () async {
      final _FakeRunner runner = _FakeRunner(verdict: 'error');
      final SrsGen4RehearsalScheduler s = _scheduler(runner);
      expect((await s.maybeRun())?.verdict, SrsGen4RehearsalVerdict.error);
      expect(await s.maybeRun(), isNull);
      // 新进程、同一版本：上一份报告是本版本的 error，不再跑。
      expect(await _scheduler(runner).maybeRun(), isNull);
      expect(runner.runs, 1);
      // 换了版本照跑。
      runner.verdict = 'pass';
      expect(
        (await _scheduler(runner, version: '1.1+2').maybeRun())?.verdict,
        SrsGen4RehearsalVerdict.pass,
      );
    });

    test(
      'a started marker left by a dead run of this version is not re-run',
      () async {
        // 上次跑到一半进程死了：内核开跑前写的 started 报告还在。
        final _FakeRunner runner = _FakeRunner(
          last: _report('started', '1.0+1'),
        );
        expect(runner.last?.verdict, SrsGen4RehearsalVerdict.interrupted);
        expect(await _scheduler(runner).maybeRun(), isNull);
        expect(runner.runs, 0);
        // 别的版本留下的 started 不算本版本的结论：照跑。
        final _FakeRunner older = _FakeRunner(
          last: _report('started', '0.9+1'),
        );
        expect(
          (await _scheduler(older).maybeRun())?.verdict,
          SrsGen4RehearsalVerdict.pass,
        );
        expect(older.runs, 1);
      },
    );

    test('a rehearsal running elsewhere in this process is neither settled nor '
        'an interruption, and the scheduler waits for it', () async {
      // 内核读到本进程里这个库的登记还在时报 running，不是 started。
      final _FakeRunner runner = _FakeRunner(last: _report('running', '1.0+1'));
      expect(runner.last?.verdict, SrsGen4RehearsalVerdict.running);
      expect(SrsGen4RehearsalVerdict.running.settled, isFalse);
      final List<Object> errors = <Object>[];
      final SrsGen4RehearsalScheduler s = _scheduler(runner, errors: errors);
      expect(await s.maybeRun(), isNull);
      expect(runner.runs, 0);
      expect(errors, isEmpty);
      // 那一次跑完、报告还不是本版本的结论（被停下了）：下个节拍照跑。
      runner.last = _report('cancelled', '1.0+1');
      expect((await s.maybeRun())?.verdict, SrsGen4RehearsalVerdict.pass);
      expect(runner.runs, 1);
    });

    test('an unfinished run (cancelled / no space) is retried later', () async {
      final _FakeRunner runner = _FakeRunner(verdict: 'skipped');
      final SrsGen4RehearsalScheduler s = _scheduler(runner);
      expect((await s.maybeRun())?.verdict, SrsGen4RehearsalVerdict.skipped);
      runner.verdict = 'pass';
      expect((await s.maybeRun())?.verdict, SrsGen4RehearsalVerdict.pass);
      expect(runner.runs, 2);
    });

    test('does not start while the app is busy', () async {
      final _FakeRunner runner = _FakeRunner();
      bool idle = false;
      final SrsGen4RehearsalScheduler s = _scheduler(runner, idle: () => idle);
      expect(await s.maybeRun(), isNull);
      expect(runner.runs, 0);
      idle = true;
      expect(await s.maybeRun(), isNotNull);
    });

    test('cancel reaches the kernel and the run is retried', () async {
      final _FakeRunner runner = _FakeRunner()..gate = Completer<void>();
      final SrsGen4RehearsalScheduler s = _scheduler(runner);
      final Future<SrsGen4RehearsalReport?> f = s.maybeRun();
      while (runner.runs == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(s.isRunning, isTrue);
      await s.quiesce();
      expect(runner.cancels, 1);
      expect((await f)?.verdict, SrsGen4RehearsalVerdict.cancelled);
      expect(s.isRunning, isFalse);
      runner
        ..gate = null
        ..cancels = 0;
      expect((await s.maybeRun())?.verdict, SrsGen4RehearsalVerdict.pass);
    });

    test('a cancel while the last report is read starts no run, and quiesce '
        'does not wait for a whole round', () async {
      final _FakeRunner runner = _FakeRunner()
        ..lastReportGate = Completer<void>()
        ..gate = Completer<void>();
      final SrsGen4RehearsalScheduler s = _scheduler(runner);
      final Future<SrsGen4RehearsalReport?> f = s.maybeRun();
      while (runner.lastReads == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final Future<void> q = s.quiesce();
      runner.lastReportGate!.complete();
      await q.timeout(const Duration(seconds: 5));
      expect(await f, isNull);
      expect(runner.runs, 0);
      expect(s.isRunning, isFalse);
      // 没跑出结论：下个节拍照跑。
      runner
        ..lastReportGate = null
        ..gate = null;
      expect((await s.maybeRun())?.verdict, SrsGen4RehearsalVerdict.pass);
    });

    test(
      'a cancel before the runner registers the run still stops it',
      () async {
        final _FakeRunner runner = _FakeRunner()
          ..beforeRegistration = Completer<void>()
          ..gate = Completer<void>();
        final SrsGen4RehearsalScheduler s = _scheduler(runner);
        final Future<SrsGen4RehearsalReport?> f = s.maybeRun();
        while (runner.runs == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        final Future<void> q = s.quiesce();
        expect(runner.cancels, 1);
        runner.beforeRegistration!.complete();
        await q.timeout(const Duration(seconds: 5));
        expect((await f)?.verdict, SrsGen4RehearsalVerdict.cancelled);
        runner
          ..beforeRegistration = null
          ..gate = null;
        expect((await s.maybeRun())?.verdict, SrsGen4RehearsalVerdict.pass);
      },
    );

    test(
      'a command error is logged once and not retried in this process',
      () async {
        final _FakeRunner runner = _FakeRunner()..error = StateError('boom');
        final List<Object> errors = <Object>[];
        final SrsGen4RehearsalScheduler s = _scheduler(runner, errors: errors);
        expect(await s.maybeRun(), isNull);
        expect(await s.maybeRun(), isNull);
        expect(runner.runs, 1);
        expect(errors, hasLength(1));
      },
    );

    test('dispose stops the ticks and cancels', () async {
      final _FakeRunner runner = _FakeRunner();
      final SrsGen4RehearsalScheduler s = _scheduler(runner)..start();
      s.dispose();
      expect(await s.maybeRun(), isNull);
      expect(runner.runs, 0);
    });
  });

  test(
    'the kernel rehearses the app library with every profile config',
    () async {
      final SrsStorage st = await openTestSrsStorage();
      final SrsDbStore s = await SrsDbStore.open(
        core: st.core,
        profileUid: kProfile,
        deviceId: 'A',
        engine: FfiFsrsEngine.tryCreate(),
      );
      await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): '猫',
        },
      );
      expect(await srsGen4RehearsalLastReport(st.core), isNull);
      final SrsGen4RehearsalReport r = await srsGen4Rehearse(
        st.core,
        appVersion: '9.9+9',
      );
      // 没有对拍差异；没做完换代前提的库报 blocked 而不是 fail。
      expect(
        r.verdict,
        anyOf(SrsGen4RehearsalVerdict.pass, SrsGen4RehearsalVerdict.blocked),
        reason: '${r.raw}',
      );
      final List<Object?> profiles = r.raw['profiles']! as List<Object?>;
      final Map<String, Object?> mine = profiles
          .cast<Map<String, Object?>>()
          .firstWhere((Map<String, Object?> p) => p['profile'] == kProfile);
      if (r.verdict == SrsGen4RehearsalVerdict.pass) {
        // 内置笔记类型的缓存配置由 Dart 给全（不是只有默认牌组）。
        expect(mine['cacheConfig'], 'given');
      }
      final SrsGen4RehearsalReport? saved = await srsGen4RehearsalLastReport(
        st.core,
      );
      expect(saved?.verdict, r.verdict);
      expect(saved?.appVersion, '9.9+9');
      // 没在跑时取消是空操作。
      srsGen4RehearsalCancel(st.core);
      // 带运行号的取消早于这一次开跑（内核登记它）到达：不丢，那一次报 cancelled。
      srsGen4RehearsalCancel(st.core, runId: 'early');
      final SrsGen4RehearsalReport stopped = await srsGen4Rehearse(
        st.core,
        appVersion: '9.9+9',
        runId: 'early',
      );
      expect(stopped.verdict, SrsGen4RehearsalVerdict.cancelled);
      await st.close();
    },
  );
}
