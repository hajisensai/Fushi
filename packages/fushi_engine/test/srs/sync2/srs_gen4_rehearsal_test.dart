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

class _FakeRunner implements SrsGen4RehearsalRunner {
  _FakeRunner({this.last, this.verdict = 'pass'});

  SrsGen4RehearsalReport? last;
  String verdict;
  Object? error;
  Completer<void>? gate;
  int runs = 0;
  int cancels = 0;

  @override
  Future<SrsGen4RehearsalReport?> lastReport() async => last;

  @override
  Future<SrsGen4RehearsalReport> run(String appVersion) async {
    runs++;
    if (gate case final Completer<void> g) await g.future;
    if (error case final Object e) throw e;
    final SrsGen4RehearsalReport r = _report(
      cancels > 0 ? 'cancelled' : verdict,
      appVersion,
    );
    last = r;
    return r;
  }

  @override
  void cancel() {
    cancels++;
    gate?.complete();
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
        db: st.db,
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
      await st.close();
    },
  );
}
