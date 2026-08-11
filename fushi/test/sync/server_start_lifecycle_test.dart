import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1573：互联 host 的启动/销毁生命周期 + 手动同步的逐通道隔离。
///
/// - `_start()` 的前半段（读端口/口令、生成 TLS 自签证书、取设备名、迁移旧同步根、
///   构造 [FushiSyncServer]）原来不在 try 内：任何一步抛出都让 `start()` 的 future 以
///   **异常**完成，而两个调用点（设置页开关 / app init）都只处理
///   [FushiServerStartOutcome]、都没有 catch → 开关停在「已开启」、无任何提示。
/// - `dispose()` 之后 `stop()` 尾部的 notifyListeners 会撞 ChangeNotifier 断言。
FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory(
      setup: (dynamic rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
    ));

/// 查词服务工厂恒抛：它在 [FushiSyncServer] 构造期被调用，即 `server.start()` 绑端口
/// **之前**——正是原来没被 try 罩住的那一段。
FushiSyncServerController _controller(FushiDatabase db) =>
    FushiSyncServerController(
      navigatorKey: GlobalKey<NavigatorState>(),
      database: () => db,
      syncDataDir: () => Directory.systemTemp.path,
      remoteLookupServiceFactory: () =>
          throw StateError('lookup factory exploded'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('启动前半段抛出 → 映射成 FushiServerStartError，而不是把异常抛给调用方', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await SyncRepository(db).setServerEnabled(true);

    // 服务构造工厂抛出：这一步在 `server.start()` 绑端口**之前**，正是原来裸奔的那段。
    final FushiSyncServerController controller = _controller(db);
    addTearDown(controller.dispose);

    final FushiServerStartOutcome outcome = await controller.start();

    expect(outcome, isA<FushiServerStartError>(),
        reason: '前半段失败与后半段失败对用户是同一件事：没起来');
    expect((outcome as FushiServerStartError).message, isNotEmpty);
    expect(controller.isRunning, isFalse);
    // 用户的 hosting 意图不因一次启动失败被抹掉（BUG-160 / HBK-AUDIT-167）。
    expect(await SyncRepository(db).isServerEnabled(), isTrue);
  });

  test('startIfEnabled 同样不把前半段异常抛出来', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await SyncRepository(db).setServerEnabled(true);
    final FushiSyncServerController controller = _controller(db);
    addTearDown(controller.dispose);

    expect(await controller.startIfEnabled(), isA<FushiServerStartError>());
  });

  test('并发两次 start 共用同一次编排，失败结果一致（BUG-1551 不回归）', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    await SyncRepository(db).setServerEnabled(true);
    final FushiSyncServerController controller = _controller(db);
    addTearDown(controller.dispose);

    final List<FushiServerStartOutcome> outcomes =
        await Future.wait(<Future<FushiServerStartOutcome>>[
      controller.start(),
      controller.start()
    ]);
    expect(outcomes[0], isA<FushiServerStartError>());
    expect(outcomes[1], isA<FushiServerStartError>());
  });

  test('dispose 后 stop 的尾部 notify 不撞 ChangeNotifier 断言', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final FushiSyncServerController controller = _controller(db);
    controller.addListener(() {});

    // AppModel.dispose 的真实顺序：先 fire-and-forget stop，再同步 dispose。
    final Future<void> stopping = controller.stop();
    controller.dispose();
    await stopping; // 旧实现在这里以「dispose 后 notify」断言失败。
  });

  test('dispose 自身幂等，且重复 stop 不炸', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final FushiSyncServerController controller = _controller(db);
    controller.dispose();
    await controller.stop();
    await controller.stop();
  });

  group('手动同步逐通道隔离（源码守卫）', () {
    // runManualFullSync 依赖 resolveSyncBackend 的进程级单例与真实网络后端，
    // 无法在单测里把「云通道抛异常、互联通道成功」摆出来。故对该函数体做结构守卫：
    // 循环里必须有 per-channel catch，且「一条都没跑成」时必须把原异常抛回去
    // （否则 manual_sync_ui 的 `on SyncAuthError` 登出分支就永远走不到）。
    final File file = File('lib/src/sync/sync_auto_trigger.dart');
    late final String manualBody;

    setUpAll(() {
      expect(file.existsSync(), isTrue, reason: '需从 fushi/ 包根运行');
      final String src = file.readAsStringSync();
      final int start =
          src.indexOf('Future<ManualSyncResult> runManualFullSync');
      expect(start, greaterThanOrEqualTo(0));
      final int end = src.indexOf('enum ', start) >= 0
          ? src.indexOf('Timer? _collectionsSyncDebounce', start)
          : src.length;
      expect(end, greaterThan(start));
      manualBody = src.substring(start, end);
    });

    test('通道循环体被 try/catch 包住', () {
      expect(manualBody.contains('} catch (e, stack) {'), isTrue,
          reason: '一条通道失败不得让其余通道的 channelReports 一起被丢弃');
      expect(manualBody.contains('merged.noteError('), isTrue,
          reason: '失败通道必须进汇总报告的 errors/authFailures，不许静默');
    });

    test('一条通道都没跑成时把原异常抛回 UI 层', () {
      expect(manualBody.contains('Error.throwWithStackTrace('), isTrue,
          reason: '全失败时必须保留原异常，否则 SyncAuthError 登出分支走不到');
    });

    test('有通道跑成时仍返回 completed + 逐通道报告', () {
      expect(manualBody.contains('ManualSyncOutcome.completed'), isTrue);
      expect(manualBody.contains('channelReports'), isTrue);
    });
  });
}
