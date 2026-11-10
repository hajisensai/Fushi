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

  @override
  Future<void> closeAsync() async => closed = true;
}
