import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// BUG-4389：配对来源分类。经反代 / 穿透进来的请求（带转发头）、无头端的回环对端
/// 一律不算局域网；可信代理只影响展示 / 限速键；P2P 区域不读转发头。
class _FakeConnectionInfo implements HttpConnectionInfo {
  _FakeConnectionInfo(String address)
    : remoteAddress = InternetAddress(address);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 40000;

  @override
  int get localPort => 8765;
}

void main() {
  late Directory tempDir;
  late FushiSyncServer server;
  late List<FushiPairRequest> approvals;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_request_origin_');
    approvals = <FushiPairRequest>[];
    server =
        FushiSyncServer(
            syncDataDir: tempDir.path,
            port: 0,
            token: 'super-secret-token',
            allowLan: true,
          )
          ..onPairRequest = ((FushiPairRequest r) async {
            approvals.add(r);
            return true;
          })
          ..lanRequiresPinProvider = (() async => false);
  });

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<shelf.Response> send(
    String path, {
    required String? peer,
    Map<String, String> headers = const <String, String>{},
    Map<String, Object> extraContext = const <String, Object>{},
  }) {
    return server.handleInProcess(
      shelf.Request(
        'POST',
        Uri.parse('http://fushi.test$path'),
        headers: <String, String>{
          'content-type': 'application/json',
          ...headers,
        },
        body: jsonEncode(<String, String>{
          'name': 'Phone',
          'clientNonce': 'cn-origin',
        }),
        context: <String, Object>{
          if (peer != null)
            'shelf.io.connection_info': _FakeConnectionInfo(peer),
          ...extraContext,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> pairV2({
    required String? peer,
    Map<String, String> headers = const <String, String>{},
    Map<String, Object> extraContext = const <String, Object>{},
  }) async {
    final shelf.Response resp = await send(
      '/api/pair/v2',
      peer: peer,
      headers: headers,
      extraContext: extraContext,
    );
    expect(resp.statusCode, 200);
    return jsonDecode(await resp.readAsString()) as Map<String, dynamic>;
  }

  test(
    '回环对端带 X-Forwarded-For（未配可信代理）：v2 要 PIN，v1 回 upgrade_required',
    () async {
      final Map<String, dynamic> body = await pairV2(
        peer: '127.0.0.1',
        headers: <String, String>{'x-forwarded-for': '203.0.113.9'},
      );
      expect(body['pinRequired'], isTrue);

      final shelf.Response v1 = await send(
        '/api/pair',
        peer: '127.0.0.1',
        headers: <String, String>{'x-forwarded-for': '203.0.113.9'},
      );
      expect(v1.statusCode, 403);
      expect(
        (jsonDecode(await v1.readAsString()) as Map<String, dynamic>)['reason'],
        'upgrade_required',
      );
      // 审批框上如实标出经过转发层。
      expect(approvals.single.remoteAddress, '127.0.0.1 (proxied)');
    },
  );

  test('局域网对端带 X-Real-IP：要 PIN', () async {
    final Map<String, dynamic> body = await pairV2(
      peer: '192.168.1.20',
      headers: <String, String>{'x-real-ip': '1.2.3.4'},
    );
    expect(body['pinRequired'], isTrue);
  });

  test('Forwarded / CF-Connecting-IP / True-Client-IP 同样按公网', () async {
    for (final MapEntry<String, String> h in <String, String>{
      'forwarded': 'for=203.0.113.9',
      'cf-connecting-ip': '203.0.113.9',
      'true-client-ip': '203.0.113.9',
    }.entries) {
      final Map<String, dynamic> body = await pairV2(
        peer: '192.168.1.20',
        headers: <String, String>{h.key: h.value},
      );
      expect(body['pinRequired'], isTrue, reason: h.key);
    }
  });

  test('局域网对端、无转发头：仍免 PIN（不回归）', () async {
    final Map<String, dynamic> body = await pairV2(peer: '192.168.1.20');
    expect(body['pinRequired'], isFalse);
  });

  test('app 默认：回环对端无转发头仍算局域网', () async {
    final Map<String, dynamic> body = await pairV2(peer: '127.0.0.1');
    expect(body['pinRequired'], isFalse);
  });

  test('loopbackPeerIsLan=false（无头端）：回环对端要 PIN', () async {
    server.loopbackPeerIsLan = false;
    expect((await pairV2(peer: '127.0.0.1'))['pinRequired'], isTrue);
    expect((await pairV2(peer: '::1'))['pinRequired'], isTrue);
    expect((await pairV2(peer: '::ffff:127.0.0.1'))['pinRequired'], isTrue);
    // 真局域网对端不受影响。
    expect((await pairV2(peer: '192.168.1.20'))['pinRequired'], isFalse);
  });

  test('可信代理：展示真实来源 + via 代理，但仍要 PIN', () async {
    server.trustedProxiesProvider = () => <String>['127.0.0.1'];
    final Map<String, dynamic> body = await pairV2(
      peer: '127.0.0.1',
      headers: <String, String>{'x-forwarded-for': '10.0.0.5, 203.0.113.9'},
    );
    expect(body['pinRequired'], isTrue);
    final String remote = approvals.single.remoteAddress!;
    expect(remote, startsWith('203.0.113.9'));
    expect(remote, contains('via 127.0.0.1'));
  });

  test('可信代理 + RFC 7239 Forwarded：取最后一个 for=', () async {
    server.trustedProxiesProvider = () => <String>['192.168.1.0/24'];
    await pairV2(
      peer: '192.168.1.2',
      headers: <String, String>{
        'forwarded': 'for=10.0.0.5;proto=https, for="[2001:db8::7]:4711"',
      },
    );
    expect(approvals.single.remoteAddress, '2001:db8::7 (via 192.168.1.2)');
  });

  test('对端不在可信代理集合：不读转发头内容', () async {
    server.trustedProxiesProvider = () => <String>['10.9.9.9'];
    await pairV2(
      peer: '127.0.0.1',
      headers: <String, String>{'x-forwarded-for': '203.0.113.9'},
    );
    expect(approvals.single.remoteAddress, '127.0.0.1 (proxied)');
  });

  test('P2P 区域：不读转发头，即使 127.0.0.1 是可信代理', () async {
    server.trustedProxiesProvider = () => <String>['127.0.0.1'];
    final Map<String, dynamic> body = await pairV2(
      peer: '127.0.0.1',
      headers: <String, String>{'x-forwarded-for': '192.168.1.9'},
      extraContext: <String, Object>{
        kFushiRequestZone: 'p2p',
        kFushiP2pPeer: 'node1',
      },
    );
    expect(body['pinRequired'], isTrue);
    final String? remote = approvals.single.remoteAddress;
    expect(remote, kFushiP2pRemoteAddress);
    expect(remote, isNot(contains('192.168.1.9')));
  });

  test('审批请求只带能区分真实来源的 sourceKey（评审 compat-3）', () async {
    // 宿主拿 sourceKey 判「同源取代常驻 PIN 框」：共用键（回环、`p2p:?`）
    // 判成同源会让陌生人顶掉别人的框，必须给 null。
    server.lanRequiresPinProvider = () async => true;
    Future<String?> keyFor({
      required String peer,
      Map<String, String> headers = const <String, String>{},
      Map<String, Object> extraContext = const <String, Object>{},
    }) async {
      approvals.clear();
      await pairV2(peer: peer, headers: headers, extraContext: extraContext);
      return approvals.single.sourceKey;
    }

    expect(await keyFor(peer: '192.168.1.20'), 'ip:192.168.1.20');
    expect(await keyFor(peer: '127.0.0.1'), isNull, reason: '回环对端');
    expect(
      await keyFor(
        peer: '192.168.1.5',
        headers: <String, String>{'x-forwarded-for': '203.0.113.9'},
      ),
      'ip:192.168.1.5',
      reason: '非回环直连对端带自填转发头：仍按真实 TCP 对端分源（评审 recheck-1）',
    );
    expect(
      await keyFor(
        peer: '127.0.0.1',
        extraContext: <String, Object>{kFushiRequestZone: 'p2p'},
      ),
      isNull,
      reason: '查不到 NodeId 的隧道对端',
    );
    expect(
      await keyFor(
        peer: '127.0.0.1',
        extraContext: <String, Object>{
          kFushiRequestZone: 'p2p',
          kFushiP2pPeer: 'node1',
        },
      ),
      'p2p:node1',
    );
    server.trustedProxiesProvider = () => <String>['127.0.0.1'];
    expect(
      await keyFor(
        peer: '127.0.0.1',
        headers: <String, String>{'x-forwarded-for': '203.0.113.9'},
      ),
      'ip:203.0.113.9',
      reason: '可信代理解析出的真实来源',
    );
  });

  test('拿不到 TCP 对端：按公网要 PIN', () async {
    final Map<String, dynamic> body = await pairV2(peer: null);
    expect(body['pinRequired'], isTrue);
  });
}
