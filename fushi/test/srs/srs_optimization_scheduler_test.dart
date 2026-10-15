// 自动优化调度（计划 PR6）：空闲判据、6 小时节流、门槛判定、写回参数组、取消
// （进入复习页 / app 进后台），以及排程内核不可用时什么都不做。用假计算任务，不跑 FFI。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_optimization_scheduler.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_optimizer.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'srs_test_support.dart';

/// 同步算完的假任务（用假内核跑真正的 srsRunOptimization）。
class _InlineJob implements SrsOptimizationJob {
  int runs = 0;
  bool cancelled = false;

  @override
  Future<SrsOptimizationResult> run(SrsOptimizationInput input) async {
    runs++;
    return srsRunOptimization(const SrsTestEngine(), input);
  }

  @override
  void cancel() => cancelled = true;
}

/// 一直算到被取消的假任务。
class _BlockingJob implements SrsOptimizationJob {
  final Completer<SrsOptimizationResult> _done =
      Completer<SrsOptimizationResult>();
  final Completer<void> started = Completer<void>();
  bool cancelled = false;

  @override
  Future<SrsOptimizationResult> run(SrsOptimizationInput input) {
    if (!started.isCompleted) started.complete();
    return _done.future;
  }

  @override
  void cancel() {
    cancelled = true;
    if (!_done.isCompleted) {
      _done.completeError(const SrsFsrsException('cancelled'));
    }
  }
}

void main() {
  late FushiDatabase db;
  late SrsDbStore store;
  late SrsTestClock clock;

  setUp(() async {
    clock = SrsTestClock();
    (db, store) = await openSrsTestStore(clock: clock);
    final String noteId = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '雪',
      },
    );
    final String cardId = (await store.cardsOfNote(noteId)).single.id;
    for (final int days in <int>[0, 1, 3, 7]) {
      clock.advance(Duration(days: days));
      await store.answer(cardId, 3);
    }
  });

  tearDown(() => db.close());

  SrsOptimizationScheduler make({
    required SrsOptimizationJob Function() job,
    bool Function()? canRun,
    FsrsEngine? engine = const SrsTestEngine(),
    DateTime Function()? now,
    void Function()? onApplied,
  }) => SrsOptimizationScheduler(
    readStore: () async => store,
    engine: () => engine,
    jobFactory: job,
    canRunNow: canRun ?? () => true,
    onApplied: onApplied,
    clock: now,
  );

  Future<SrsParamSet?> paramSet() async {
    final SrsDeckView owner = (await store.deckTree()).paramsOwner(
      store.defaultDeckId,
    );
    return owner.paramSetFor(owner.localAlgorithm);
  }

  test('有训练数据（前提）', () async {
    final SrsOptimizationInput? input = await srsPrepareOptimization(
      store,
      store.defaultDeckId,
    );
    expect(input, isNotNull);
    expect(input!.reviewCount, greaterThan(0));
  });

  test('不空闲（在复习页 / 后台）：不跑、不建任务', () async {
    int jobs = 0;
    final SrsOptimizationScheduler s = make(
      job: () {
        jobs++;
        return _InlineJob();
      },
      canRun: () => false,
    );
    addTearDown(s.dispose);
    expect(await s.maybeRun(), isNull);
    expect(jobs, 0);
  });

  test('样本没到门槛：检查了牌组但不训练；6 小时内不再检查', () async {
    DateTime now = DateTime(2026, 10, 15, 9);
    final _InlineJob job = _InlineJob();
    final SrsOptimizationScheduler s = make(job: () => job, now: () => now);
    addTearDown(s.dispose);
    final SrsOptimizationRound? r1 = await s.maybeRun();
    expect(r1, isNotNull);
    expect(r1!.checkedDecks, contains(store.defaultDeckId));
    expect(r1.applied, isEmpty, reason: '远低于 $kSrsOptimizeMinItems 条');
    expect(job.runs, 0);
    now = now.add(const Duration(hours: 5));
    expect(await s.maybeRun(), isNull, reason: '6 小时节流');
    now = now.add(const Duration(hours: 2));
    expect(await s.maybeRun(), isNotNull);
  });

  test('「立即优化」：跳过门槛训练并写回参数组（机器产出）', () async {
    int applied = 0;
    final _InlineJob job = _InlineJob();
    final SrsOptimizationScheduler s = make(
      job: () => job,
      onApplied: () => applied++,
    );
    addTearDown(s.dispose);
    expect(await paramSet(), isNull);
    final SrsOptimizationRound? r = await s.runNow(
      onlyDeckId: store.defaultDeckId,
      force: true,
    );
    expect(r!.applied, hasLength(1));
    expect(job.runs, 1);
    expect(applied, 1);
    final SrsParamSet? set = await paramSet();
    expect(set, isNotNull);
    expect(set!.optimizedAt, isNotNull);
    expect(set.logLoss, isNotNull);
    expect(set.algorithmRev, 'fake');
  });

  test('取消：进入复习页 / 进后台时在跑的那一轮作废，不写参数', () async {
    final _BlockingJob job = _BlockingJob();
    final SrsOptimizationScheduler s = make(job: () => job);
    addTearDown(s.dispose);
    final Future<SrsOptimizationRound?> running = s.runNow(
      onlyDeckId: store.defaultDeckId,
      force: true,
    );
    await job.started.future;
    expect(s.isRunning, isTrue);
    s.cancel();
    final SrsOptimizationRound? r = await running;
    expect(job.cancelled, isTrue);
    expect(r!.cancelled, isTrue);
    expect(r.applied, isEmpty);
    expect(await paramSet(), isNull);
    expect(s.isRunning, isFalse);
  });

  test('排程内核不可用：什么都不做', () async {
    int jobs = 0;
    final SrsOptimizationScheduler s = make(
      job: () {
        jobs++;
        return _InlineJob();
      },
      engine: null,
    );
    addTearDown(s.dispose);
    expect(await s.runNow(force: true), isNull);
    expect(jobs, 0);
  });
}
