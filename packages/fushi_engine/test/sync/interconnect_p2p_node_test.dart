import 'dart:async';

import 'package:fushi_engine/sync/interconnect_p2p.dart';
import 'package:test/test.dart';

/// 转发口 → 持久 `p2p://` 地址的反查映射与转发口同生命周期：换提示撤口、关端点
/// 时随口一起回收（旧口不再被当成隧道）。
void main() {
  final String nodeHex = 'b' * 64;
  String origin(String relay) =>
      interconnectP2pUrl(nodeHex, tls: false, relayUrl: relay);

  late _FakePort port;
  late InterconnectP2pNode node;

  setUp(() {
    port = _FakePort();
    node = InterconnectP2pNode.forTesting(port, 'self');
  });

  tearDown(() => node.close());

  test('同提示复用同一口，映射指向持久地址', () {
    final int a = node.forwardTo(
      nodeHex,
      relayUrl: 'r1',
      originUrl: origin('r1'),
    );
    final int b = node.forwardTo(
      nodeHex,
      relayUrl: 'r1',
      originUrl: origin('r1'),
    );
    expect(b, a);
    expect(interconnectTunnelOriginUrl('127.0.0.1', a), origin('r1'));
    expect(interconnectTunnelOriginUrl('localhost', a), origin('r1'));
    expect(interconnectTunnelOriginUrl('192.168.1.5', a), isNull);
    expect(isInterconnectTunnelOrigin('127.0.0.1', a), isTrue);
    expect(port.stopped, isEmpty);
  });

  test('换提示撤口：旧口映射回收，新口映射新地址', () {
    final int a = node.forwardTo(
      nodeHex,
      relayUrl: 'r1',
      originUrl: origin('r1'),
    );
    final int b = node.forwardTo(
      nodeHex,
      relayUrl: 'r2',
      originUrl: origin('r2'),
    );
    expect(b, isNot(a));
    expect(port.stopped, <int>[a]);
    expect(interconnectTunnelOriginUrl('127.0.0.1', a), isNull);
    expect(isInterconnectTunnelOrigin('127.0.0.1', a), isFalse);
    expect(interconnectTunnelOriginUrl('127.0.0.1', b), origin('r2'));
  });

  test('关端点：本节点全部口的映射回收', () async {
    final int a = node.forwardTo(
      nodeHex,
      relayUrl: 'r1',
      originUrl: origin('r1'),
    );
    final int c = node.forwardTo(
      'c' * 64,
      relayUrl: 'r1',
      originUrl: 'p2p://c',
    );
    await node.close();
    expect(interconnectTunnelOriginUrl('127.0.0.1', a), isNull);
    expect(interconnectTunnelOriginUrl('127.0.0.1', c), isNull);
    expect(isInterconnectTunnelOrigin('127.0.0.1', c), isFalse);
    expect(port.closed, isTrue);
  });

  group('网络变化通知', () {
    late int secretLoads;
    late InterconnectP2pRuntime runtime;

    setUp(() {
      secretLoads = 0;
      runtime = InterconnectP2pRuntime(
        loadSecret: () async {
          secretLoads++;
          return null;
        },
        saveSecret: (String _) async {},
        loadRelayUrls: () async => const <String>[],
      );
    });

    test('端点未启动：不为此建端点，也不调原生', () {
      runtime.notifyNetworkChange();
      expect(runtime.current, isNull);
      expect(secretLoads, 0);
      expect(port.networkChanges, 0);
    });

    test('装了节点：每次通知转给端点一次', () {
      runtime.debugInstall(node);
      runtime.notifyNetworkChange();
      expect(port.networkChanges, 1);
    });

    test('节点已关闭：不再调原生', () async {
      runtime.debugInstall(node);
      await node.close();
      runtime.notifyNetworkChange();
      expect(port.networkChanges, 0);
    });

    test('原生抛异常：留痕不外抛，下一次照常送达', () {
      runtime.debugInstall(node);
      port.throwOnNetworkChange = true;
      expect(runtime.notifyNetworkChange, returnsNormally);
      port.throwOnNetworkChange = false;
      runtime.notifyNetworkChange();
      expect(port.networkChanges, 2);
    });

    test('信号流每个事件转成一次通知，取消订阅后不再转', () async {
      runtime.debugInstall(node);
      final StreamController<void> signals = StreamController<void>();
      final StreamSubscription<void> sub = bindInterconnectP2pNetworkSignals(
        runtime,
        signals.stream,
      );
      signals
        ..add(null)
        ..add(null);
      await Future<void>.delayed(Duration.zero);
      expect(port.networkChanges, 2);
      await sub.cancel();
      expect(signals.hasListener, isFalse);
      await signals.close();
    });
  });
}

final class _FakePort implements InterconnectP2pEndpointPort {
  int _next = 6001;
  final List<int> stopped = <int>[];
  bool closed = false;

  @override
  int clientForward(
    String nodeId, {
    List<String> directAddrs = const <String>[],
    String? relayUrl,
  }) => _next++;

  @override
  bool stopForward(int port) {
    stopped.add(port);
    return true;
  }

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

  int networkChanges = 0;
  bool throwOnNetworkChange = false;

  @override
  bool networkChange() {
    networkChanges++;
    if (throwOnNetworkChange) throw const FushiP2pException('boom');
    return true;
  }

  @override
  Future<void> closeAsync() async => closed = true;
}
