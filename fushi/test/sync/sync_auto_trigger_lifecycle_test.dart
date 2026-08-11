import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1569 守卫：互联自动同步触发层的三处生命周期缺口。
///
/// ① 离线探测零退避：成功冷却戳 lastSyncMs 只在整轮 sweep 完整跑成后写
///    （TODO-1332），通道异常发生在写戳之前 → 首页每分钟 tick 每次都全额重付
///    候选串行探测。修：失败结局推进内存态退避戳（固定 5 分钟），成功清零。
/// ② collectionsSyncWatcher 生产无卸载：关库路径必须撤订阅 + 取消未决防抖
///    Timer，否则 Timer 到点对已关闭 db 跑轻量同步（源码守卫 + 行为测试）。
/// ③ 退出书同步被整轮 sweep 静默丢弃：sweep 进行中的 per-book 请求改为记账，
///    sweep 收尾去重补跑。
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
  const int cooldownMs = 5 * 60 * 1000; // 与 _syncCooldownMs 保持一致

  setUp(resetAutoSweepFailureBackoffForTest);
  tearDown(() {
    resetAutoSweepFailureBackoffForTest();
    debugMarkSweepInProgress(false);
  });

  group('BUG-1569① 失败退避状态机', () {
    test('失败推进固定退避窗，窗内判退避、窗满放行', () {
      const int now = 1000000;
      expect(isAutoSweepBackedOff(nowMs: now), isFalse);

      noteAutoSweepOutcomeForBackoff(SyncOutcomeReason.failed, nowMs: now);
      expect(isAutoSweepBackedOff(nowMs: now), isTrue);
      expect(isAutoSweepBackedOff(nowMs: now + cooldownMs - 1), isTrue);
      expect(isAutoSweepBackedOff(nowMs: now + cooldownMs), isFalse,
          reason: '固定退避：窗满必须放行重试');
    });

    test('completed 清零退避；cooledDown/noChannels/autoDisabled 不触碰', () {
      const int now = 1000000;
      noteAutoSweepOutcomeForBackoff(SyncOutcomeReason.failed, nowMs: now);
      expect(isAutoSweepBackedOff(nowMs: now), isTrue);

      noteAutoSweepOutcomeForBackoff(SyncOutcomeReason.cooledDown, nowMs: now);
      noteAutoSweepOutcomeForBackoff(SyncOutcomeReason.noChannels, nowMs: now);
      noteAutoSweepOutcomeForBackoff(SyncOutcomeReason.autoDisabled,
          nowMs: now);
      expect(isAutoSweepBackedOff(nowMs: now), isTrue, reason: '非成败结局不得改写退避戳');

      noteAutoSweepOutcomeForBackoff(SyncOutcomeReason.completed, nowMs: now);
      expect(isAutoSweepBackedOff(nowMs: now), isFalse,
          reason: '成功（对端活了）必须恢复正常节奏');
    });
  });

  group('BUG-1569① 全量 sweep 失败路径推进退避（集成）', () {
    test('对端离线：第一轮 failed 置退避，第二轮 cooledDown 跳过探测', () async {
      final FushiDatabase db = _memDb();
      final Directory work =
          await Directory.systemTemp.createTemp('bug1569_backoff_');
      addTearDown(() async {
        await db.close();
        if (work.existsSync()) await work.delete(recursive: true);
      });
      final SyncRepository repo = SyncRepository(db);
      await repo.setAutoSyncEnabled(true);
      // 唯一通道 = 互联（云备份后端也选成互联，dedup 后只剩一条），指向一个
      // 已关闭端口 → 连接拒绝 → 全候选探测失败 → SyncBackendError → 通道失败。
      await repo.setBackendType(SyncBackendType.fushiServer);
      final ServerSocket dead =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int deadPort = dead.port;
      await dead.close();
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: 'http://127.0.0.1:$deadPort'),
      ]);
      await repo.setFushiClientToken('tok');

      Future<SyncOutcomeReason> runOnce() async {
        lastSyncOutcome.value = null;
        await runAutoSyncAllForTest(
          db: db,
          dictionaryResourceRoot: work,
          audioDatabaseRoot: work,
          tempDir: work,
        );
        return lastSyncOutcome.value!.reason;
      }

      expect(await runOnce(), SyncOutcomeReason.failed,
          reason: '对端离线的通道异常必须如实记为 failed');
      expect(autoSweepFailureBackoffUntilMsForTest, isNotNull,
          reason: '失败结局必须推进退避戳（BUG-1569①）');

      final Stopwatch watch = Stopwatch()..start();
      expect(await runOnce(), SyncOutcomeReason.cooledDown,
          reason: '退避窗内的下一次自动 sweep 必须被闸掉，'
              '不得再全额重付候选串行探测');
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(1000),
          reason: '被闸掉的轮次只做本地判断，不得走网络');
    });
  });

  group('BUG-1569② 合集观察者生命周期', () {
    test('uninstall 取消未决防抖 Timer：不再对（已关）库跑轻量同步', () async {
      final FushiDatabase db = _memDb();
      installCollectionsSyncWatcher(
        db: db,
        debounce: const Duration(milliseconds: 50),
      );
      final int scheduledBefore = collectionsSyncScheduledForTest;
      await db.createMediaCollection('Fav');
      await _waitFor(
        () => collectionsSyncScheduledForTest > scheduledBefore,
        what: 'collections write to schedule a debounced sync',
      );

      // 关库路径语义：先撤观察者（取消 Timer），再关库。
      uninstallCollectionsSyncWatcher();
      lastSyncOutcome.value = null;
      await db.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(lastSyncOutcome.value, isNull,
          reason: '未决防抖 Timer 必须随 uninstall 取消，'
              '否则会对已关闭的 db 跑 _runCollectionsSync（BUG-1569②）');
    });

    test('源码守卫：AppModel 三条关库/销毁路径都撤观察者', () {
      final File f = File('lib/src/models/app_model.dart');
      expect(f.existsSync(), isTrue,
          reason: 'run from the fushi/ package root');
      final String src = f.readAsStringSync();

      String slice(String start, String end) {
        final int a = src.indexOf(start);
        expect(a, greaterThan(-1), reason: 'missing: $start');
        final int b = src.indexOf(end, a);
        expect(b, greaterThan(a), reason: 'missing end marker after $start');
        return src.substring(a, b);
      }

      expect(
        slice('Future<void> closeDatabase()', 'Future<void> shutdown()'),
        contains('uninstallCollectionsSyncWatcher()'),
        reason: 'closeDatabase 必须撤合集观察者（BUG-1569②）',
      );
      expect(
        slice('Future<void> closeForPopup()', 'void dispose()'),
        contains('uninstallCollectionsSyncWatcher()'),
        reason: 'closeForPopup 必须撤合集观察者（BUG-1569②）',
      );
      expect(
        // 终点用带分号的真调用——dispose 顶部的 doc 注释里也写了「super.dispose()」，
        // 不带分号的标记会把切片截在注释处。
        slice('void dispose() {', 'super.dispose();'),
        contains('uninstallCollectionsSyncWatcher()'),
        reason: 'dispose 必须对称撤合集观察者（BUG-1569②）',
      );
    });
  });

  group('BUG-1569③ sweep 期间的退出书同步记账补跑', () {
    test('sweep 进行中记账（去重），收尾 drain 补跑', () async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);

      expect(debugMarkSweepInProgress(true), isTrue);
      triggerAutoSyncOnBackground(db: db, mediaIdentifier: 'fushi://book/abc');
      // 同步入队（记账发生在 _runAutoSync 的第一段同步代码里，无 await 之前）。
      await _waitFor(() => pendingBookSyncCountForTest == 1,
          what: 'per-book request to be recorded during sweep');
      triggerAutoSyncOnBackground(db: db, mediaIdentifier: 'fushi://book/abc');
      await Future<void>.delayed(Duration.zero);
      expect(pendingBookSyncCountForTest, 1,
          reason: '同一本书在 sweep 期间反复退出只记一笔（去重）');

      debugMarkSweepInProgress(false);
      lastSyncOutcome.value = null;
      drainPendingBookSyncsAfterSweep();
      expect(pendingBookSyncCountForTest, 0, reason: '补跑后账目清空');
      await _waitFor(() => lastSyncOutcome.value != null,
          what: 'replayed per-book sync to finish');
      expect(lastSyncOutcome.value!.kind, SyncActivityKind.singleBook,
          reason: '被 sweep 挡下的请求必须真的补跑（此前是静默丢弃）');
    });

    test('源码守卫：自动与手动两条全量 sweep 收尾都接了补跑', () {
      final File f = File('lib/src/sync/sync_auto_trigger.dart');
      expect(f.existsSync(), isTrue,
          reason: 'run from the fushi/ package root');
      final String src = f.readAsStringSync();
      expect(
        'drainPendingBookSyncsAfterSweep();'.allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: '_runAutoSyncAll 与 runManualFullSync 的 finally 都必须补跑'
            ' sweep 期间记账的退出书同步（BUG-1569③）——上面的行为用例只测'
            '记账与 drain 本身，不测 finally 接线',
      );
    });
  });
}
