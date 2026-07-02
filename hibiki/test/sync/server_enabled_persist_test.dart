import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/hibiki_server_controller.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// BUG-160: 绑定失败不能抹掉用户的持久化"想开服"意图。
///
/// 修复前：`start()` 失败路径调 `repo.setServerEnabled(false)`，下次启动开关变关。
/// 修复后：绑定失败保留意图 true，仅由用户显式关闭（`stop(persistDisabled:true)`）清除。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BUG-160: server-enabled intent persists across bind failures', () {
    test('PortInUse failure preserves serverEnabled=true', () async {
      // controller 以 allowLan=true 启动，会绑定 wildcard 地址；这里同样占用
      // wildcard 端口，避免 macOS 上 loopback-only 监听不阻止 0.0.0.0 绑定。
      final ServerSocket blocker = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        0,
        shared: false,
      );
      addTearDown(() => blocker.close());
      final int takenPort = blocker.port;

      final Directory dir =
          await Directory.systemTemp.createTemp('hibiki_ctl_persist_');
      addTearDown(() => dir.delete(recursive: true));

      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      // 预设用户意图：想开服，使用被占用的端口。
      await repo.setServerEnabled(true);
      await repo.setServerPort(takenPort);

      // 注意：_remoteLookupServiceFactory 在 HibikiSyncServer 构造时（绑定前）被调用，
      // 不是在绑定成功后。所以即使端口被占用，factory 也会被调用——使用 no-op 桩。
      final HibikiSyncServerController controller = HibikiSyncServerController(
        navigatorKey: GlobalKey<NavigatorState>(),
        database: () => db,
        syncDataDir: () => dir.path,
        remoteLookupServiceFactory: () => _NoopLookupService(),
      );

      final HibikiServerStartOutcome outcome = await controller.start();

      // 必须返回 PortInUse outcome（断言 start() 真的失败了）。
      expect(outcome, isA<HibikiServerPortInUse>(),
          reason: '端口被占用，start() 必须返回 PortInUse');
      expect((outcome as HibikiServerPortInUse).port, equals(takenPort));

      // 核心断言：持久化意图必须仍为 true（修复前此处为 false）。
      expect(await repo.isServerEnabled(), isTrue,
          reason: '绑定失败不应抹掉用户的持久化开服意图');

      // controller 本次未成功绑定，isRunning 应为 false。
      expect(controller.isRunning, isFalse);
    });

    test(
        'source guard: start() failure paths do NOT call setServerEnabled(false)',
        () {
      // 泛 catch 路径（非 PortInUse）在真实测试中难以可靠触发（低端口 Win 可绑）。
      // 用源码扫描守卫：确认两处失败路径均不含 setServerEnabled(false)。
      // 修复前：catch 块含 `await repo.setServerEnabled(false);`
      // 修复后：catch 块只有 `_server = null` / `notifyListeners()` / return。
      final String src =
          File('lib/src/sync/hibiki_server_controller.dart').readAsStringSync();

      // 定位 start() 方法体（从方法签名到下一个顶层方法）
      final int startIdx =
          src.indexOf('Future<HibikiServerStartOutcome> start()');
      final int stopIdx = src.indexOf('Future<void> stop(', startIdx);
      expect(startIdx, isNot(-1), reason: 'start() 方法必须存在');
      expect(stopIdx, isNot(-1), reason: 'stop() 方法必须存在');

      final String startBody = src.substring(startIdx, stopIdx);

      // start() 失败路径（on SyncServerPortInUseException + catch(e)）
      // 不得再调用 setServerEnabled(false)。
      // 成功路径中有 setServerEnabled(true)，但失败路径不得有 false。
      final RegExp setFalseInCatch = RegExp(
        r'on\s+SyncServerPortInUseException.*?setServerEnabled\(false\)',
        dotAll: true,
      );
      final RegExp setFalseInCatchGeneral = RegExp(
        r'catch\s*\(e\).*?setServerEnabled\(false\)',
        dotAll: true,
      );

      expect(setFalseInCatch.hasMatch(startBody), isFalse,
          reason: 'PortInUse 分支不得调用 setServerEnabled(false)（会抹掉用户意图）');
      expect(setFalseInCatchGeneral.hasMatch(startBody), isFalse,
          reason: '泛 catch 分支不得调用 setServerEnabled(false)（会抹掉用户意图）');
    });

    test('successful bind writes serverEnabled=true', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('hibiki_ctl_ok_');
      addTearDown(() => dir.delete(recursive: true));

      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      // 使用端口 0（OS 自动分配），绑定一定成功。
      await repo.setServerEnabled(true);
      await repo.setServerPort(0);

      final HibikiSyncServerController controller = HibikiSyncServerController(
        navigatorKey: GlobalKey<NavigatorState>(),
        database: () => db,
        syncDataDir: () => dir.path,
        remoteLookupServiceFactory: () => _NoopLookupService(),
      );
      addTearDown(() => controller.stop());

      final HibikiServerStartOutcome outcome = await controller.start();

      expect(outcome, isA<HibikiServerStarted>(), reason: '端口 0 应当绑定成功');
      expect(await repo.isServerEnabled(), isTrue,
          reason: '成功路径必须保持/写入 serverEnabled=true');
      expect(controller.isRunning, isTrue);
    });

    test('stop(persistDisabled:true) clears serverEnabled intent', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('hibiki_ctl_stop_');
      addTearDown(() => dir.delete(recursive: true));

      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setServerEnabled(true);
      await repo.setServerPort(0);

      final HibikiSyncServerController controller = HibikiSyncServerController(
        navigatorKey: GlobalKey<NavigatorState>(),
        database: () => db,
        syncDataDir: () => dir.path,
        remoteLookupServiceFactory: () => _NoopLookupService(),
      );

      await controller.start();
      expect(controller.isRunning, isTrue);

      // 用户显式关闭 → 应清意图。
      await controller.stop(persistDisabled: true);

      expect(await repo.isServerEnabled(), isFalse,
          reason: '用户显式关闭时 persistDisabled:true 必须清掉意图');
    });

    test('stop() without persistDisabled preserves intent', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('hibiki_ctl_transient_');
      addTearDown(() => dir.delete(recursive: true));

      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setServerEnabled(true);
      await repo.setServerPort(0);

      final HibikiSyncServerController controller = HibikiSyncServerController(
        navigatorKey: GlobalKey<NavigatorState>(),
        database: () => db,
        syncDataDir: () => dir.path,
        remoteLookupServiceFactory: () => _NoopLookupService(),
      );

      await controller.start();
      expect(controller.isRunning, isTrue);

      // app 退出/瞬时停 → 不传 persistDisabled → 保留意图。
      await controller.stop();

      expect(await repo.isServerEnabled(), isTrue,
          reason: 'app 退出/瞬时停不应清掉意图，下次启动要恢复');
    });
  });
}

/// 最小 no-op 查词服务桩，用于需要真实绑定的测试。
class _NoopLookupService implements HibikiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async =>
      null;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async =>
      null;
}
