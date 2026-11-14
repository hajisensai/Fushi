import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_p2p_app.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart';

/// BUG：P2P 隧道不知道系统网络变化。平台「默认网络变了」信号与回到前台
/// （resumed，补 iOS 睡眠检测一小时才轮询一次的缺口）都要转成一次
/// `networkChange`，其余生命周期状态不转。
void main() {
  late _FakePort port;
  late InterconnectP2pNode node;
  late InterconnectP2pRuntime runtime;

  setUp(() {
    port = _FakePort();
    node = InterconnectP2pNode.forTesting(port, 'self');
    runtime = InterconnectP2pRuntime(
      loadSecret: () async => null,
      saveSecret: (String _) async {},
      loadRelayUrls: () async => const <String>[],
    )..debugInstall(node);
  });

  tearDown(() async {
    debugResetAppInterconnectP2p();
    await node.close();
  });

  test('网络变化信号与 resumed 各转成一次通知，其余生命周期状态不转', () async {
    final StreamController<void> changes = StreamController<void>();
    final StreamController<AppLifecycleState> lifecycle =
        StreamController<AppLifecycleState>();
    installInterconnectP2pNetworkWatch(
      runtime,
      changes: changes.stream,
      lifecycle: lifecycle.stream,
    );

    changes.add(null);
    lifecycle
      ..add(AppLifecycleState.inactive)
      ..add(AppLifecycleState.paused)
      ..add(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(port.networkChanges, 2);

    // 撤掉装配后不再转发，也不再挂着平台流。
    debugResetAppInterconnectP2p();
    expect(changes.hasListener, isFalse);
    expect(lifecycle.hasListener, isFalse);
    await changes.close();
    await lifecycle.close();
  });

  test('重复装配只保留最后一份订阅', () async {
    final StreamController<void> first = StreamController<void>();
    final StreamController<void> second = StreamController<void>();
    installInterconnectP2pNetworkWatch(
      runtime,
      changes: first.stream,
      lifecycle: const Stream<AppLifecycleState>.empty(),
    );
    installInterconnectP2pNetworkWatch(
      runtime,
      changes: second.stream,
      lifecycle: const Stream<AppLifecycleState>.empty(),
    );
    expect(first.hasListener, isFalse);
    second.add(null);
    await pumpEventQueue();
    expect(port.networkChanges, 1);
    await first.close();
    await second.close();
  });

  test('平台流报错（原生侧没注册）只留痕，后续信号照常送达', () async {
    final StreamController<void> changes = StreamController<void>();
    installInterconnectP2pNetworkWatch(
      runtime,
      changes: changes.stream,
      lifecycle: const Stream<AppLifecycleState>.empty(),
    );
    changes
      ..addError(StateError('no native side'))
      ..add(null);
    await pumpEventQueue();
    expect(port.networkChanges, 1);
    await changes.close();
  });
}

final class _FakePort implements InterconnectP2pEndpointPort {
  int networkChanges = 0;

  @override
  int clientForward(
    String nodeId, {
    List<String> directAddrs = const <String>[],
    String? relayUrl,
  }) => throw UnimplementedError();

  @override
  bool stopForward(int port) => true;

  @override
  FushiP2pConnStatus status(String nodeId) => throw UnimplementedError();

  @override
  FushiP2pInfo info() => throw UnimplementedError();

  @override
  void hostListen(int port) {}

  @override
  void hostStop() {}

  @override
  String? hostPeer(int port) => null;

  @override
  bool networkChange() {
    networkChanges++;
    return true;
  }

  @override
  Future<void> closeAsync() async {}
}
