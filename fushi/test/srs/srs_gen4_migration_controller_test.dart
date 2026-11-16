// G7-5：换代迁移控制器（srs_gen4_migration_controller.dart）——假执行端，不碰原生库。
// 覆盖：每个 profile 交一份缓存配置、轮询进度、提交点前后能否取消、各种结论 / 报错落到 outcome / error、
// 提交后才调 onCommitted、跑着时重复 start 无操作、关库前的 quiesce（提交点前叫停并等、之后只等）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_gen4_migration_controller.dart';
import 'package:fushi_srs/fushi_srs.dart';

class FakeGen4Backend implements SrsGen4MigrationBackend {
  Completer<SrsGen4MigrationOutcome> pending =
      Completer<SrsGen4MigrationOutcome>();
  SrsGen4MigrationProgress? running;
  final List<Map<String, Map<String, Object?>>> runs =
      <Map<String, Map<String, Object?>>>[];
  final List<String?> cancels = <String?>[];
  String? lastRunId;
  Error? statusError;

  @override
  SrsGen4MigrationStatus status(String dir) {
    final Error? e = statusError;
    if (e != null) throw e;
    return SrsGen4MigrationStatus.fromJson(<String, Object?>{
      'state': 'needsMigration',
      'running': running == null
          ? null
          : <String, Object?>{
              'step': running!.step.wire,
              'done': running!.done,
              'total': running!.total,
            },
    });
  }

  @override
  Future<SrsGen4MigrationOutcome> run(
    String dir, {
    required Map<String, Map<String, Object?>> caches,
    required int nowMs,
    required String runId,
  }) {
    runs.add(caches);
    lastRunId = runId;
    return pending.future;
  }

  @override
  bool cancel(String dir, {String? runId}) {
    cancels.add(runId);
    return true;
  }

  void finish(Map<String, Object?> json) =>
      pending.complete(SrsGen4MigrationOutcome.fromJson(json));
}

SrsGen4MigrationController controllerFor(
  FakeGen4Backend backend, {
  List<String> profiles = const <String>['p1', 'p2'],
  Future<void> Function()? onCommitted,
}) => SrsGen4MigrationController(
  directory: 'dir',
  profileUids: () async => profiles,
  onCommitted: onCommitted ?? () async {},
  backend: backend,
  pollInterval: const Duration(milliseconds: 5),
  nowMs: () => 1000,
);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  test('start hands one cache config per profile and polls progress', () async {
    final FakeGen4Backend b = FakeGen4Backend();
    final SrsGen4MigrationController c = controllerFor(b);
    addTearDown(c.dispose);
    final Future<void> done = c.start();
    await settle();
    expect(c.phase, SrsGen4MigrationPhase.running);
    expect(b.runs.single.keys, <String>['p1', 'p2']);
    expect(c.progress, isNull);
    expect(c.canCancel, isTrue, reason: '还没轮询到进度时按提交点之前算');

    b.running = (step: SrsGen4MigrationStep.translate, done: 3, total: 10);
    await settle();
    expect(c.progress?.step, SrsGen4MigrationStep.translate);
    expect(c.progress?.done, 3);

    // 跑着时再点开始：无操作（不起第二次）。
    await c.start();
    expect(b.runs, hasLength(1));

    b.finish(<String, Object?>{'verdict': 'cancelled'});
    await done;
    expect(c.phase, SrsGen4MigrationPhase.idle);
    expect(c.outcome?.verdict, SrsGen4MigrationVerdict.cancelled);
  });

  test(
    'cancel works before the commit point only and passes the run id',
    () async {
      final FakeGen4Backend b = FakeGen4Backend();
      final SrsGen4MigrationController c = controllerFor(b);
      addTearDown(c.dispose);
      final Future<void> done = c.start();
      await settle();
      b.running = (step: SrsGen4MigrationStep.parity, done: 1, total: 2);
      await settle();
      c.cancel();
      expect(b.cancels, <String?>[b.lastRunId]);
      expect(c.cancelRequested, isTrue);
      expect(c.canCancel, isFalse, reason: '已请求过');
      c.cancel();
      expect(b.cancels, hasLength(1), reason: '不重复发');
      b.finish(<String, Object?>{'verdict': 'cancelled'});
      await done;
      expect(c.cancelRequested, isFalse);

      final FakeGen4Backend b2 = FakeGen4Backend();
      final SrsGen4MigrationController c2 = controllerFor(b2);
      addTearDown(c2.dispose);
      final Future<void> done2 = c2.start();
      b2.running = (step: SrsGen4MigrationStep.commit, done: 0, total: 1);
      await settle();
      expect(c2.canCancel, isFalse, reason: '到了提交点就不能取消');
      c2.cancel();
      expect(b2.cancels, isEmpty);
      b2.finish(<String, Object?>{'verdict': 'committed'});
      await done2;
    },
  );

  test('committed calls onCommitted once and ends in committed', () async {
    final FakeGen4Backend b = FakeGen4Backend();
    int committed = 0;
    final SrsGen4MigrationController c = controllerFor(
      b,
      onCommitted: () async => committed++,
    );
    addTearDown(c.dispose);
    final Future<void> done = c.start();
    await settle();
    expect(committed, 0);
    b.finish(<String, Object?>{
      'verdict': 'committed',
      'report': <String, Object?>{},
    });
    await done;
    expect(committed, 1);
    expect(c.phase, SrsGen4MigrationPhase.committed);
    expect(c.outcome, isNull);
  });

  test('non-committed verdicts land in outcome with their details', () async {
    for (final Map<String, Object?> json in <Map<String, Object?>>[
      <String, Object?>{'verdict': 'noSpace', 'needed': 5000, 'free': 1000},
      <String, Object?>{'verdict': 'blocked', 'reason': 'another process'},
      <String, Object?>{
        'verdict': 'aborted',
        'reportPath': 'dir/srs4-migration-report.json',
        'report': <String, Object?>{'verdict': 'aborted'},
      },
    ]) {
      final FakeGen4Backend b = FakeGen4Backend();
      int committed = 0;
      final SrsGen4MigrationController c = controllerFor(
        b,
        onCommitted: () async => committed++,
      );
      final Future<void> done = c.start();
      b.finish(json);
      await done;
      final SrsGen4MigrationOutcome o = c.outcome!;
      expect(o.verdict.wire, json['verdict']);
      expect(committed, 0);
      expect(c.phase, SrsGen4MigrationPhase.idle);
      if (o.verdict == SrsGen4MigrationVerdict.noSpace) {
        expect(o.neededBytes, 5000);
        expect(o.freeBytes, 1000);
      }
      if (o.verdict == SrsGen4MigrationVerdict.aborted) {
        expect(o.reportPath, 'dir/srs4-migration-report.json');
      }
      c.dispose();
    }
  });

  group('quiesce (before the database closes)', () {
    test('idle: returns at once, no cancel sent', () async {
      final FakeGen4Backend b = FakeGen4Backend();
      final SrsGen4MigrationController c = controllerFor(b);
      addTearDown(c.dispose);
      await c.quiesce();
      expect(b.cancels, isEmpty);
    });

    test(
      'before the commit point: cancels, then waits for the verdict',
      () async {
        final FakeGen4Backend b = FakeGen4Backend();
        final SrsGen4MigrationController c = controllerFor(b);
        addTearDown(c.dispose);
        final Future<void> done = c.start();
        b.running = (step: SrsGen4MigrationStep.translate, done: 1, total: 9);
        await settle();
        bool quiesced = false;
        final Future<void> q = c.quiesce().then((_) => quiesced = true);
        await settle();
        expect(b.cancels, <String?>[b.lastRunId], reason: '提交点之前叫停');
        expect(quiesced, isFalse, reason: '结论出来之前不放行关库');
        b.finish(<String, Object?>{'verdict': 'cancelled'});
        await q;
        await done;
        expect(quiesced, isTrue);
        expect(c.phase, SrsGen4MigrationPhase.idle);
      },
    );

    test('past the commit point: no cancel, waits for it to finish', () async {
      final FakeGen4Backend b = FakeGen4Backend();
      int committed = 0;
      final SrsGen4MigrationController c = controllerFor(
        b,
        onCommitted: () async => committed++,
      );
      addTearDown(c.dispose);
      final Future<void> done = c.start();
      b.running = (step: SrsGen4MigrationStep.seal, done: 0, total: 1);
      await settle();
      bool quiesced = false;
      final Future<void> q = c.quiesce().then((_) => quiesced = true);
      await settle();
      expect(b.cancels, isEmpty);
      expect(quiesced, isFalse, reason: '改名 / 封存进行中不放行关库');
      b.finish(<String, Object?>{'verdict': 'committed'});
      await q;
      await done;
      expect(committed, 1);
    });
  });

  test('a kernel error lands in error, not swallowed as success', () async {
    final FakeGen4Backend b = FakeGen4Backend();
    final SrsGen4MigrationController c = controllerFor(b);
    addTearDown(c.dispose);
    // 轮询读不到进度只是显示问题：不影响结论。
    b.statusError = StateError('status failed');
    final Future<void> done = c.start();
    await settle();
    b.pending.completeError(const SrsCoreException(-1, 'boom'));
    await done;
    expect(c.error, isA<SrsCoreException>());
    expect(c.outcome, isNull);
    expect(c.phase, SrsGen4MigrationPhase.idle);
  });
}
