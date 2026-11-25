import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/local_audio_manager.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_module_gate.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_resource_locks.dart';
import 'package:fushi/src/sync/sync_task_board.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

/// 反馈 SJeJd5EEZO 另一半（#3105 遗留）：关掉「同步与备份 + 互联」模块时立刻停掉
/// 同步——在飞的协作式取消（安全检查点中止、不留半写状态 / 锁 / 冷却戳），门关着的
/// 入口一律不开跑，重新打开即恢复。
FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 可在任意时刻翻转的取消信号（编排器层测试用；生产里是模块门发的票）。
class _Flag implements SyncCancellation {
  bool cancelled = false;

  @override
  bool get isCancelled => cancelled;

  @override
  void throwIfCancelled() {
    if (cancelled) throw const SyncCancelledException();
  }
}

/// 认证探测可挂起的通道后端：用来把一轮手动同步停在「第一条通道进行中」。
class _HoldingBackend implements SyncBackend {
  _HoldingBackend(this.name, this.log);

  final String name;
  final List<String> log;
  Completer<void>? hold;
  final Completer<void> entered = Completer<void>();

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    log.add(name);
    if (!entered.isCompleted) entered.complete();
    final Completer<void>? gate = hold;
    if (gate != null) await gate.future;
    return false;
  }

  @override
  Future<bool> get isAuthenticated async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected ${invocation.memberName}');
}

SyncOrchestrator _orchestrator(
  FushiDatabase db,
  SyncBackend backend,
  Directory root, {
  required SyncCancellation cancellation,
  required void Function(SyncProgress) onProgress,
}) => SyncOrchestrator(
  db: db,
  backend: backend,
  dictionaryResourceRoot: root,
  audioDatabaseRoot: root,
  tempDir: root,
  syncStats: false,
  syncAudioBookPosition: false,
  syncContent: false,
  syncMangaContent: false,
  syncAudioBookFiles: false,
  syncDictionary: true,
  onProgress: onProgress,
  cancellation: cancellation,
);

Future<ManualSyncResult> _manual(FushiDatabase db, Directory work) =>
    runManualFullSync(
      db: db,
      dictionaryResourceRoot: work,
      audioDatabaseRoot: work,
      tempDir: work,
      localAudioEntries: const <LocalAudioDbEntry>[],
      onLocalAudioImported: (LocalAudioPackageContents _) async {},
    );

void main() {
  late Directory work;

  setUp(() async {
    resetSyncModuleGateForTest();
    resetSyncTasksForTest();
    resetAutoSweepFailureBackoffForTest();
    lastSyncOutcome.value = null;
    lastFullSweepOutcome.value = null;
    work = await Directory.systemTemp.createTemp('sync_module_gate_');
  });

  tearDown(() async {
    debugSyncChannelsOverride = null;
    resetSyncModuleGateForTest();
    resetSyncTasksForTest();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  group('SyncModuleGate', () {
    test('关门取消全部在飞票、拒发新票；开门恢复发票，已取消的票不复活', () {
      final SyncModuleGate gate = SyncModuleGate();
      final SyncRunTicket a = gate.enter()!;
      final SyncRunTicket b = gate.enter()!;
      b.leave();
      expect(gate.liveCount, 1);

      gate.setOpen(false);
      expect(a.isCancelled, isTrue);
      expect(
        () => a.throwIfCancelled(),
        throwsA(isA<SyncCancelledException>()),
      );
      expect(b.isCancelled, isFalse, reason: '已结束的那一轮不受影响');
      expect(gate.enter(), isNull, reason: '门关着不得开跑');

      gate.setOpen(true);
      final SyncRunTicket c = gate.enter()!;
      expect(c.isCancelled, isFalse);
      expect(a.isCancelled, isTrue, reason: '被取消的那一轮不会因为重新开门而续跑');
      a.leave();
      c.leave();
      expect(gate.liveCount, 0);
    });
  });

  group('编排器安全检查点', () {
    test('整轮 sweep 在阶段之间中止：后续阶段不跑，冷却戳不写', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final _Flag flag = _Flag();
      final List<SyncPhase> phases = <SyncPhase>[];

      await expectLater(
        _orchestrator(
          db,
          FakeSyncBackend(FakeAssetStore()),
          work,
          cancellation: flag,
          onProgress: (SyncProgress p) {
            phases.add(p.phase);
            // 合集阶段开工时模块被关掉。
            if (p.phase == SyncPhase.collections) flag.cancelled = true;
          },
        ).run(),
        throwsA(isA<SyncCancelledException>()),
      );

      expect(phases, contains(SyncPhase.collections));
      expect(
        phases,
        isNot(contains(SyncPhase.deletions)),
        reason: '取消后不得再进入下一阶段',
      );
      expect(
        await SyncRepository(db).getLastSyncMs(SyncChannelScope.unscoped),
        isNull,
        reason: '被取消的一轮不算跑完，不得写冷却戳压制下次同步',
      );
    });

    test('逐项循环在两项之间中止：已开始的那一项完整落地，下一项不开始', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      for (final String name in <String>['dictA', 'dictB']) {
        await db.upsertDictionaryMeta(
          DictionaryMetadataCompanion.insert(
            name: name,
            formatKey: 'yomitan',
            order: 0,
            type: const Value('term'),
            metadataJson: const Value('{}'),
            hiddenLanguagesJson: const Value('[]'),
            collapsedLanguagesJson: const Value('[]'),
          ),
        );
        Directory('${work.path}/$name').createSync(recursive: true);
        File('${work.path}/$name/index.json').writeAsStringSync('{}');
      }
      final FakeAssetStore store = FakeAssetStore();
      final _Flag flag = _Flag();
      final SyncRunReport report = SyncRunReport();

      await expectLater(
        _orchestrator(
          db,
          FakeSyncBackend(store),
          work,
          cancellation: flag,
          onProgress: (SyncProgress p) {
            // 第一项的开工 tick（不带字节进度）一到，模块就被关掉。
            if (p.phase == SyncPhase.dictionaries && p.fileFraction == null) {
              flag.cancelled = true;
            }
          },
        ).syncDictionaries(report, direction: SyncAssetDirection.both),
        throwsA(isA<SyncCancelledException>()),
      );

      expect(
        report.dictionariesExported,
        1,
        reason: '检查点不打断进行中的一项：第一本完整上传，第二本不开始',
      );
      expect(report.errors, isEmpty, reason: '取消不是失败，不得记成逐项错误');
    });
  });

  group('同步入口经模块门', () {
    test('门关着：手动同步不开跑、不点亮在飞、不公布结局', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final List<String> log = <String>[];
      debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[
        SyncChannel(
          _HoldingBackend('cloud', log),
          type: SyncBackendType.webDav,
          isInterconnect: false,
        ),
      ];
      final List<bool> inFlight = <bool>[];
      void record() => inFlight.add(syncInProgress.value);
      syncInProgress.addListener(record);
      addTearDown(() => syncInProgress.removeListener(record));

      syncModuleGate.setOpen(false);
      final ManualSyncResult result = await _manual(db, work);

      expect(result.outcome, ManualSyncOutcome.moduleDisabled);
      expect(log, isEmpty, reason: '门关着不得碰任何通道');
      expect(inFlight, isNot(contains(true)));
      expect(lastSyncOutcome.value, isNull);

      // 重新打开模块：同一入口恢复开跑。
      syncModuleGate.setOpen(true);
      final ManualSyncResult again = await _manual(db, work);
      expect(again.outcome, ManualSyncOutcome.notConfigured);
      expect(log, <String>['cloud']);
    });

    test('门关着：自动 sweep 不开跑、不公布「自动同步已关」', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      await SyncRepository(db).setAutoSyncEnabled(true);
      final List<String> log = <String>[];
      debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[
        SyncChannel(
          _HoldingBackend('cloud', log),
          type: SyncBackendType.webDav,
          isInterconnect: false,
        ),
      ];

      syncModuleGate.setOpen(false);
      await runAutoSyncAllForTest(
        db: db,
        dictionaryResourceRoot: work,
        audioDatabaseRoot: work,
        tempDir: work,
      );

      expect(log, isEmpty);
      expect(lastSyncOutcome.value, isNull);
      expect(syncInProgress.value, isFalse);
    });

    test('在飞的手动同步途中关模块：收在下一个检查点，后续通道不跑，锁与票全还', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final List<String> log = <String>[];
      final _HoldingBackend cloud = _HoldingBackend('cloud', log)
        ..hold = Completer<void>();
      final _HoldingBackend interconnect = _HoldingBackend('interconnect', log);
      debugSyncChannelsOverride = (SyncRepository _) async => <SyncChannel>[
        SyncChannel(cloud, type: SyncBackendType.webDav, isInterconnect: false),
        SyncChannel(
          interconnect,
          type: SyncBackendType.fushiServer,
          isInterconnect: true,
        ),
      ];

      final Future<ManualSyncResult> run = _manual(db, work);
      await cloud.entered.future;
      expect(syncInProgress.value, isTrue);
      expect(syncModuleGate.liveCount, 1);

      syncModuleGate.setOpen(false);
      cloud.hold!.complete();
      final ManualSyncResult result = await run;

      expect(result.outcome, ManualSyncOutcome.cancelled);
      expect(log, <String>['cloud'], reason: '取消后不得再进下一条通道');
      expect(lastFullSweepOutcome.value?.reason, SyncOutcomeReason.cancelled);
      expect(syncInProgress.value, isFalse);
      expect(syncModuleGate.liveCount, 0, reason: '票必须随任务结束交还');
      expect(syncResourceLocks.isHeld(kSyncRoundResource), isFalse);
      expect(
        isAutoSweepBackedOff(nowMs: DateTime.now().millisecondsSinceEpoch),
        isFalse,
        reason: '取消不是失败，不得推进失败退避',
      );
    });
  });
}
