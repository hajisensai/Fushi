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
}
