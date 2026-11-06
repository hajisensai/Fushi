import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-3305：自动同步关着时，三条自动路径（开机 / 定时 sweep、合集轻量、退出书
/// 单本）一律不得让 [syncInProgress] 置真。
///
/// 原实现先 `_beginSyncActivity` 登记在飞、再排 `_autoSyncMutex`、最后才读开关，
/// 于是同步全关的用户每次定时 tick / 切后台都会让「同步进行中」白白亮一段。
FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<void> _waitFor(bool Function() cond, {String what = 'condition'}) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late FushiDatabase db;
  late Directory work;
  late List<bool> observed;

  void record() => observed.add(syncInProgress.value);

  setUp(() async {
    db = _memDb();
    work = await Directory.systemTemp.createTemp('bug3305_');
    observed = <bool>[];
    syncInProgress.addListener(record);
    lastSyncOutcome.value = null;
    resetAutoSweepFailureBackoffForTest();
  });

  tearDown(() async {
    syncInProgress.removeListener(record);
    await db.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  test('开关关着：自动全量 sweep 不置在飞，结局记 autoDisabled', () async {
    expect(await SyncRepository(db).isAutoSyncEnabled(), isFalse);
    await runAutoSyncAllForTest(
      db: db,
      dictionaryResourceRoot: work,
      audioDatabaseRoot: work,
      tempDir: work,
    );
    expect(
      observed,
      isNot(contains(true)),
      reason: '自动同步关着时 syncInProgress 一刻也不能为真',
    );
    expect(syncInProgress.value, isFalse);
    expect(lastSyncOutcome.value?.reason, SyncOutcomeReason.autoDisabled);
    expect(lastSyncOutcome.value?.kind, SyncActivityKind.fullSweep);
    expect(
      lastFullSweepOutcome.value?.reason,
      SyncOutcomeReason.autoDisabled,
      reason: '设置页「上次同步」照旧能显示「自动同步已关」',
    );
  });

  test('开关关着：合集轻量同步不置在飞', () async {
    await runCollectionsSyncNow(db: db);
    expect(observed, isNot(contains(true)));
    expect(lastSyncOutcome.value?.reason, SyncOutcomeReason.autoDisabled);
    expect(lastSyncOutcome.value?.kind, SyncActivityKind.collections);
  });

  test('开关关着：退出书单本同步不置在飞', () async {
    await runAutoSyncForBookForTest(
      db: db,
      mediaIdentifier: 'fushi://book/abc',
    );
    expect(observed, isNot(contains(true)));
    expect(lastSyncOutcome.value?.reason, SyncOutcomeReason.autoDisabled);
    expect(lastSyncOutcome.value?.kind, SyncActivityKind.singleBook);
  });

  test('开关开着：在飞标志照常成对置位与复位（没有破坏真同步的指示）', () async {
    await SyncRepository(db).setAutoSyncEnabled(true);
    await runAutoSyncForBookForTest(
      db: db,
      mediaIdentifier: 'fushi://book/abc',
    );
    expect(observed, <bool>[true, false], reason: '真要跑的同步必须先置真、结束后复位');
    expect(syncInProgress.value, isFalse);
  });

  group('门前开着、排锁期间被关：拿到锁后复核开关，不跑', () {
    /// 先占住同步互斥锁（模拟一轮很长的手动「立即同步」），开关开着时触发 [run]；
    /// 等它过了门前那道判断、排上锁（在飞标志已点亮）后把开关关掉，再放锁。
    ///
    /// 修复前开关只在锁外读一次，拿到锁后照样往下跑：单本因书不在库落成
    /// nothingToSync、合集与 sweep 因没有通道落成 noChannels——都不是 autoDisabled。
    Future<void> runQueuedThenDisabled(Future<void> Function() run) async {
      final SyncRepository repo = SyncRepository(db);
      await repo.setAutoSyncEnabled(true);
      final Completer<void> release = Completer<void>();
      final Future<void> holder = runExclusiveWithSync<void>(
        () => release.future,
      );
      final Future<void> queued = run();
      await _waitFor(
        () => syncInProgress.value,
        what: 'auto sync to pass the gate and queue on the mutex',
      );
      await repo.setAutoSyncEnabled(false);
      release.complete();
      await holder;
      await queued;
    }

    test('退出书单本', () async {
      await runQueuedThenDisabled(
        () => runAutoSyncForBookForTest(
          db: db,
          mediaIdentifier: 'fushi://book/abc',
        ),
      );
      expect(lastSyncOutcome.value?.kind, SyncActivityKind.singleBook);
      expect(
        lastSyncOutcome.value?.reason,
        SyncOutcomeReason.autoDisabled,
        reason: '排锁期间开关被关，拿到锁后必须不跑',
      );
      expect(lastSyncOutcome.value?.channelsRun, 0);
      expect(syncInProgress.value, isFalse);
    });

    test('合集轻量', () async {
      await runQueuedThenDisabled(() => runCollectionsSyncNow(db: db));
      expect(lastSyncOutcome.value?.kind, SyncActivityKind.collections);
      expect(lastSyncOutcome.value?.reason, SyncOutcomeReason.autoDisabled);
      expect(lastSyncOutcome.value?.channelsRun, 0);
      expect(syncInProgress.value, isFalse);
    });

    test('自动全量 sweep', () async {
      await runQueuedThenDisabled(
        () => runAutoSyncAllForTest(
          db: db,
          dictionaryResourceRoot: work,
          audioDatabaseRoot: work,
          tempDir: work,
        ),
      );
      expect(
        lastFullSweepOutcome.value?.reason,
        SyncOutcomeReason.autoDisabled,
      );
      expect(lastFullSweepOutcome.value?.channelsRun, 0);
      expect(
        autoSweepFailureBackoffUntilMsForTest,
        isNull,
        reason: 'autoDisabled 不触碰失败退避戳',
      );
      expect(syncInProgress.value, isFalse);
    });
  });

  group('开关关着、整轮 sweep（含手动立即同步）在飞：被挡下的自动触发不公布结局', () {
    const SyncRunOutcome previous = SyncRunOutcome(
      kind: SyncActivityKind.fullSweep,
      reason: SyncOutcomeReason.completed,
      channelsRun: 1,
      finishedAt: 1,
    );

    setUp(() {
      expect(debugMarkSweepInProgress(true), isTrue);
      lastSyncOutcome.value = previous;
      lastFullSweepOutcome.value = previous;
    });

    tearDown(() {
      debugMarkSweepInProgress(false);
    });

    void expectUntouched() {
      expect(
        lastSyncOutcome.value,
        same(previous),
        reason: '在飞的那轮 sweep 自己会公布真结局，门这里不得抢写 autoDisabled',
      );
      expect(
        lastFullSweepOutcome.value,
        same(previous),
        reason: '设置页 / 桌面控制通道在手动同步期间不得读到「自动同步已关」',
      );
    }

    test('定时 sweep', () async {
      await runAutoSyncAllForTest(
        db: db,
        dictionaryResourceRoot: work,
        audioDatabaseRoot: work,
        tempDir: work,
      );
      expectUntouched();
      expect(observed, isNot(contains(true)));
    });

    test('合集轻量', () async {
      await runCollectionsSyncNow(db: db);
      expectUntouched();
    });

    test('退出书单本', () async {
      await runAutoSyncForBookForTest(
        db: db,
        mediaIdentifier: 'fushi://book/abc',
      );
      expectUntouched();
      expect(pendingBookSyncCountForTest, 0, reason: '开关关着的触发不记补跑账');
    });
  });

  test('开关关着、没有 sweep 在飞：照旧公布 autoDisabled（不公布只限 sweep 在飞时）', () async {
    lastFullSweepOutcome.value = null;
    await runAutoSyncAllForTest(
      db: db,
      dictionaryResourceRoot: work,
      audioDatabaseRoot: work,
      tempDir: work,
    );
    expect(lastFullSweepOutcome.value?.reason, SyncOutcomeReason.autoDisabled);
  });
}
