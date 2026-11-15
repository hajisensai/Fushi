import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart'
    show kInterconnectP2pEnabledPref;

/// app 端 P2P 挂载生命周期（H8）：挂载、卸载、启动回滚都必须走控制器的
/// `_serializeP2p` 串行队列。修复前 `stop()` 直连运行时 `hostStop()`、启动回滚
/// 根本不 `hostStop()`，`_attachP2p` 最后一道检查先求 `stillWanted()` 再 await
/// 偏好——stop 落在这次 await 里时，`hostListen` 发生在 `hostStop` 之后，隧道对
/// 公网开着却没有 host。

/// 记录 host 侧隧道调用序列；端点「立即就绪」。
class _FakeP2pPort implements InterconnectP2pHostPort {
  final List<String> calls = <String>[];

  /// 端点启动这一次 await 上要做的事（测试在此插入 stop）。
  void Function()? onEnsure;

  @override
  bool get available => true;

  @override
  Future<bool> ensure() async {
    onEnsure?.call();
    return true;
  }

  @override
  void hostListen(int port) => calls.add('hostListen');

  @override
  void hostStop() => calls.add('hostStop');

  @override
  String? hostPeer(int remotePort) => null;

  @override
  List<InterconnectHostAddress> hostAddresses({required bool tls}) =>
      const <InterconnectHostAddress>[];

  @override
  Future<void> restart() async => calls.add('restart');
}

/// 广播成功（不碰平台通道）。
class _NoopBroadcast implements BonsoirBroadcast {
  _NoopBroadcast(this.service);

  @override
  final BonsoirService service;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 在「读 P2P 偏好」这次 await 上插入动作：attach 的每道偏好检查都经这里。
class _P2pPrefReadHook extends QueryInterceptor {
  /// 返回 true 表示已处理（之后不再回调）。参数是本次是第几次读（从 1 起）。
  bool Function(int read)? onRead;
  int _reads = 0;

  void arm(bool Function(int read) action) {
    _reads = 0;
    onRead = action;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    final bool Function(int read)? action = onRead;
    if (action != null && args.contains(kInterconnectP2pEnabledPref)) {
      _reads++;
      if (action(_reads)) onRead = null;
    }
    return executor.runSelect(statement, args);
  }
}

class _NoopLookupService implements FushiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => null;

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}

Future<
  ({
    FushiSyncServerController controller,
    _FakeP2pPort port,
    SyncRepository repo,
    _P2pPrefReadHook hook,
  })
>
_setUp({
  required bool p2pEnabled,
  required BonsoirBroadcast Function(BonsoirService) broadcastFactory,
}) async {
  final Directory dir = await Directory.systemTemp.createTemp('fushi_p2p_lc_');
  addTearDown(() => dir.delete(recursive: true));
  final _P2pPrefReadHook hook = _P2pPrefReadHook();
  final FushiDatabase db = FushiDatabase.forTesting(
    NativeDatabase.memory().interceptWith(hook),
  );
  addTearDown(db.close);
  final SyncRepository repo = SyncRepository(db);
  await repo.setServerEnabled(true);
  await repo.setServerPort(0);
  await repo.setInterconnectP2pEnabled(p2pEnabled);
  final _FakeP2pPort port = _FakeP2pPort();
  final FushiSyncServerController controller = FushiSyncServerController(
    navigatorKey: GlobalKey<NavigatorState>(),
    database: () => db,
    syncDataDir: () => dir.path,
    remoteLookupServiceFactory: () => _NoopLookupService(),
    p2pHostPort: () => port,
    broadcastFactory: broadcastFactory,
  );
  return (controller: controller, port: port, repo: repo, hook: hook);
}

/// 序列里最后一次 hostListen 之后必须还有 hostStop（或从未 hostListen）。
bool _listenClosed(List<String> calls) {
  final int lastListen = calls.lastIndexOf('hostListen');
  if (lastListen < 0) return true;
  return calls.lastIndexOf('hostStop') > lastListen;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // attach 里的 await 依次是：读偏好#1 → ensure → 读偏好#2 → 起信任区监听口 →
  // 读偏好#3 → hostListen。stop 精确落在每个 await 上各跑一遍（不靠墙钟）。
  for (final String point in <String>['pref#1', 'ensure', 'pref#2', 'pref#3']) {
    test('stop 落在 attach 的 $point 上：hostStop 之后不再 hostListen', () async {
      final setup = await _setUp(
        p2pEnabled: false,
        broadcastFactory: (BonsoirService s) => _NoopBroadcast(s),
      );
      final FushiSyncServerController controller = setup.controller;
      addTearDown(controller.dispose);
      expect(await controller.start(), isA<FushiServerStarted>());
      expect(setup.port.calls, isEmpty, reason: 'P2P 偏好关时启动不挂隧道');

      Future<void>? stopping;
      // stop 不能在钩子里 await：修复后它要排在这次 attach 之后。
      void fire() => stopping ??= controller.stop();
      if (point == 'ensure') {
        setup.port.onEnsure = fire;
      } else {
        final int target = int.parse(point.substring('pref#'.length));
        setup.hook.arm((int read) {
          if (read != target) return false;
          fire();
          return true;
        });
      }

      await controller.setP2pEnabled(true);
      expect(stopping, isNotNull, reason: '钩子必须真的落在 $point 上');
      await stopping;
      final List<String> atStop = List<String>.of(setup.port.calls);
      await Future<void>.delayed(Duration.zero);

      expect(
        _listenClosed(setup.port.calls),
        isTrue,
        reason: '隧道挂着却已没有 host：${setup.port.calls}',
      );
      expect(setup.port.calls, atStop, reason: 'stop 完成后不得再有隧道调用');
    });
  }

  test('stop 落在 attach 任一 await 上，都不会在 hostStop 之后残留 hostListen', () async {
    final List<String> failures = <String>[];
    for (int k = 0; k <= 40; k++) {
      final setup = await _setUp(
        p2pEnabled: false,
        broadcastFactory: (BonsoirService s) => _NoopBroadcast(s),
      );
      final FushiSyncServerController controller = setup.controller;
      expect(await controller.start(), isA<FushiServerStarted>());
      expect(setup.port.calls, isEmpty, reason: 'P2P 偏好关时启动不挂隧道');

      final Future<void> enabling = controller.setP2pEnabled(true);
      for (int i = 0; i < k; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await controller.stop();
      final List<String> atStop = List<String>.of(setup.port.calls);
      // 让残余 attach（若有）跑完再判。
      await enabling;
      await Future<void>.delayed(Duration.zero);
      controller.dispose();

      final List<String> calls = setup.port.calls;
      if (!_listenClosed(calls)) {
        failures.add('k=$k: $calls');
      } else if (calls.length > atStop.length &&
          calls.sublist(atStop.length).contains('hostListen')) {
        failures.add('k=$k: stop 完成后又 hostListen $calls');
      }
    }
    expect(failures, isEmpty);
  });

  test('启动广播失败回滚时卸下已挂上的隧道', () async {
    final setup = await _setUp(
      p2pEnabled: true,
      broadcastFactory: (BonsoirService s) =>
          throw StateError('broadcast exploded'),
    );
    final FushiSyncServerController controller = setup.controller;
    addTearDown(controller.dispose);

    final FushiServerStartOutcome outcome = await controller.start();

    expect(outcome, isA<FushiServerStartError>());
    expect(controller.isRunning, isFalse);
    expect(setup.port.calls, contains('hostListen'), reason: '广播之前隧道已挂上');
    expect(setup.port.calls.last, 'hostStop', reason: '回滚必须把隧道一起卸下');
  });
}
