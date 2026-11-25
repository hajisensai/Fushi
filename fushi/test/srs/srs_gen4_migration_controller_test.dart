// G7-5：换代迁移控制器（srs_gen4_migration_controller.dart）——假执行端，不碰原生库。
// 覆盖：每个 profile 交一份缓存配置、轮询进度、提交点前后能否取消、各种结论 / 报错落到 outcome / error、
// 提交后才调 onCommitted、跑着时重复 start 无操作、关库前的 quiesce（提交点前叫停并等、之后只等）。
import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
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

  /// `gen4_migrate_profiles`（旧库里的 profile，内核列；后台 isolate）。
  List<String> legacyUids = const <String>[];
  Error? legacyError;
  int legacyCalls = 0;

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
  Future<List<String>> legacyProfiles(String dir) async {
    legacyCalls++;
    final Error? e = legacyError;
    if (e != null) throw e;
    return legacyUids;
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
    'orphan profiles listed by the kernel get a cache config too (union)',
    () async {
      final FakeGen4Backend b = FakeGen4Backend()
        ..legacyUids = <String>['p2', 'orphan'];
      final SrsGen4MigrationController c = controllerFor(b);
      addTearDown(c.dispose);
      final Future<void> done = c.start();
      await settle();
      expect(b.runs.single.keys.toSet(), <String>{'p1', 'p2', 'orphan'});
      // 配置只取决于 uid：孤儿 uid 拿到的就是它自己的那份。
      expect(b.runs.single['orphan'], isNotEmpty);
      b.finish(<String, Object?>{'verdict': 'cancelled'});
      await done;
    },
  );

  test('no new run once the database is closing', () async {
    final FakeGen4Backend b = FakeGen4Backend();
    bool open = true;
    final SrsGen4MigrationController c = SrsGen4MigrationController(
      directory: 'dir',
      profileUids: () async => <String>['p1'],
      onCommitted: () async {},
      backend: b,
      databaseOpen: () => open,
      pollInterval: const Duration(milliseconds: 5),
      nowMs: () => 1000,
    );
    addTearDown(c.dispose);
    expect(c.canStart, isTrue);
    open = false;
    expect(c.canStart, isFalse);
    await c.start();
    expect(b.runs, isEmpty, reason: '关库之后开始的迁移没人等（静默已经过了）');
    expect(c.phase, SrsGen4MigrationPhase.idle);
    await c.quiesce();
    expect(b.cancels, isEmpty);
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
        'failure': <String, Object?>{
          'reason': 'error',
          'reportPath': 'dir/srs4-migration-report.json',
        },
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
        expect(o.failure?.reason, SrsGen4MigrationFailureReason.error);
        expect(c.failureFor(null)?.reportPath, o.reportPath);
      }
      c.dispose();
    }
  });

  test(
    'the failure on offer is the kernel reason, then the latest verdict',
    () async {
      final FakeGen4Backend b = FakeGen4Backend();
      final SrsGen4MigrationController c = SrsGen4MigrationController(
        directory: 'dir',
        profileUids: () async => <String>['p1'],
        onCommitted: () async {},
        backend: b,
        nowMs: () => 1,
      );
      addTearDown(c.dispose);
      // 上次的原因由内核在打开错误里给（SrsStoreNotMigrated.failure），控制器原样转交，不读报告文件。
      const SrsGen4MigrationFailure previous = SrsGen4MigrationFailure(
        reason: SrsGen4MigrationFailureReason.incomplete,
        reportPath: 'dir/old-report.json',
      );
      expect(c.failureFor(previous), previous);
      expect(c.failureFor(null), isNull);

      // 在跑：没有可说明的失败；又一次中止：以这次内核给的原因为准。
      Future<void> done = c.start();
      expect(c.failureFor(previous), isNull);
      b.finish(<String, Object?>{
        'verdict': 'aborted',
        'reportPath': 'dir/new-report.json',
        'failure': <String, Object?>{
          'reason': 'fail',
          'reportPath': 'dir/new-report.json',
        },
      });
      await done;
      expect(
        c.failureFor(previous),
        const SrsGen4MigrationFailure(
          reason: SrsGen4MigrationFailureReason.fail,
          reportPath: 'dir/new-report.json',
        ),
      );

      // 这次被拦下：这次没有失败可说明，也不回头拿上次的。
      b.pending = Completer<SrsGen4MigrationOutcome>();
      done = c.start();
      b.finish(<String, Object?>{'verdict': 'blocked', 'code': 'busy'});
      await done;
      expect(c.failureFor(previous), isNull);

      // 这次出错（内核报错）：同上。
      b.pending = Completer<SrsGen4MigrationOutcome>();
      done = c.start();
      await settle();
      b.pending.completeError(const SrsCoreException(-1, 'boom'));
      await done;
      expect(c.error, isNotNull);
      expect(c.failureFor(previous), isNull);
    },
  );

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

  test(
    'an unreadable legacy profile list falls back to the main profiles',
    () async {
      final FakeGen4Backend b = FakeGen4Backend()
        ..legacyError = StateError('list failed');
      final SrsGen4MigrationController c = controllerFor(b);
      addTearDown(c.dispose);
      final Future<void> done = c.start();
      await settle();
      expect(b.legacyCalls, 1);
      // 列不出来只记日志：按主库的给，真缺了内核拦下并点名（missingCacheConfig）。
      expect(b.runs.single.keys, <String>['p1', 'p2']);
      b.finish(<String, Object?>{'verdict': 'cancelled'});
      await done;
    },
  );

  test('starting up is not closing; reopening re-enables start', () async {
    final FakeGen4Backend b = FakeGen4Backend();
    final ChangeNotifier closing = ChangeNotifier();
    final ChangeNotifier changed = ChangeNotifier();
    addTearDown(closing.dispose);
    addTearDown(changed.dispose);
    // 启动中：主库还没初始化完。
    bool open = false;
    final SrsGen4MigrationController c = SrsGen4MigrationController(
      directory: 'dir',
      profileUids: () async => <String>['p1'],
      onCommitted: () async {},
      backend: b,
      databaseOpen: () => open,
      databaseClosing: closing,
      databaseChanged: changed,
      pollInterval: const Duration(milliseconds: 5),
      nowMs: () => 1000,
    );
    addTearDown(c.dispose);
    int notified = 0;
    c.addListener(() => notified++);
    expect(c.canStart, isFalse);
    expect(c.databaseClosing, isFalse, reason: '还没开好不等于正在关');
    // 初始化完成（AppModel 通知）：能开始了，页面收到通知。
    open = true;
    changed.notifyListeners();
    expect(c.canStart, isTrue);
    expect(notified, 1);
    // AppModel 的别的通知（canStart 没变）不打扰页面。
    changed.notifyListeners();
    expect(notified, 1);
    // 关库：置灰、说明「正在关」。
    open = false;
    closing.notifyListeners();
    expect(c.canStart, isFalse);
    expect(c.databaseClosing, isTrue);
    expect(notified, 2);
    // 重新开库（覆盖恢复 / 换数据根之后）：按钮恢复，不再算「正在关」。
    open = true;
    changed.notifyListeners();
    expect(c.canStart, isTrue);
    expect(c.databaseClosing, isFalse);
    expect(notified, 3);
    final Future<void> done = c.start();
    await settle();
    expect(b.runs, hasLength(1));
    b.finish(<String, Object?>{'verdict': 'cancelled'});
    await done;
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
