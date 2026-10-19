import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_api_access_policy.dart';
import 'package:fushi/src/sync/fushi_api_server.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

class _NoLookup implements FushiRemoteLookupService {
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

/// 本机一个非回环 IPv4：连它时服务端看到的来源就是该地址（不是 127.0.0.1），
/// 这样无需第二台设备就能走真实的「非本机请求」路径。
Future<InternetAddress> _lanAddress() async {
  final List<NetworkInterface> interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  for (final NetworkInterface i in interfaces) {
    for (final InternetAddress a in i.addresses) {
      if (!a.isLoopback && !a.isLinkLocal) return a;
    }
  }
  fail('本机没有非回环 IPv4 地址，无法验证非本机请求路径');
}

Future<int> _post(
  InternetAddress host,
  int port,
  String path, {
  String? apiKey,
}) async {
  // 显式直连：本机若设了 HTTP(S)_PROXY，HttpClient 会把发往局域网地址的请求交给
  // 代理（回环地址才自动直连），测到的就成了代理而不是本服务。
  final HttpClient client = HttpClient()..findProxy = (Uri _) => 'DIRECT';
  try {
    final HttpClientRequest req = await client.open(
      'POST',
      host.address,
      port,
      path,
    );
    if (apiKey != null) req.headers.set('x-api-key', apiKey);
    req.headers.contentType = ContentType.json;
    req.write('{}');
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  FushiApiServer? server;
  late InternetAddress lan;

  setUpAll(() async {
    lan = await _lanAddress();
  });

  tearDown(() async {
    await server?.stop();
    server = null;
  });

  Future<FushiApiServer> start(
    FushiApiAccessPolicy policy, {
    String? apiKey,
  }) async {
    final FushiApiServer s = FushiApiServer(
      port: 0,
      lookupService: _NoLookup(),
      tokenizer: (List<String> ts) async => <List<TokenizedSegment>>[
        for (final String t in ts) <TokenizedSegment>[(text: t, reading: '')],
      ],
      apiKey: apiKey,
      accessPolicy: policy,
    );
    await s.start();
    return server = s;
  }

  const FushiApiAccessPolicy lanPolicy = FushiApiAccessPolicy(
    mode: FushiApiAccessMode.lan,
  );

  test('局域网 + 未设密钥：本机照常可用，非本机 403（此前全网放行）', () async {
    final FushiApiServer s = await start(lanPolicy);
    expect(
      await _post(InternetAddress.loopbackIPv4, s.port, '/serverVersion'),
      200,
    );
    expect(await _post(lan, s.port, '/serverVersion'), 403);
    // 免密钥路径（音频文件 / 试一试页）同样先过网络层。
    expect(await _post(lan, s.port, '/api/lookup/audio/file'), 403);
  });

  test('局域网 + 已设密钥：非本机凭密钥可用，缺密钥 401', () async {
    final FushiApiServer s = await start(lanPolicy, apiKey: 'k1');
    expect(await _post(lan, s.port, '/serverVersion'), 401);
    expect(await _post(lan, s.port, '/serverVersion', apiKey: 'k1'), 200);
  });

  test('指定网段：不在白名单 403；在白名单凭密钥可用', () async {
    final FushiApiServer outside = await start(
      FushiApiAccessPolicy(
        mode: FushiApiAccessMode.allowList,
        allowedNetworks: <FushiIpNetwork>[
          FushiIpNetwork.tryParse('203.0.113.0/24')!,
        ],
      ),
      apiKey: 'k1',
    );
    expect(await _post(lan, outside.port, '/serverVersion', apiKey: 'k1'), 403);
    expect(
      await _post(
        InternetAddress.loopbackIPv4,
        outside.port,
        '/serverVersion',
        apiKey: 'k1',
      ),
      200,
    );
    await outside.stop();
    server = null;

    final FushiApiServer inside = await start(
      FushiApiAccessPolicy(
        mode: FushiApiAccessMode.allowList,
        allowedNetworks: <FushiIpNetwork>[
          FushiIpNetwork.tryParse('${lan.address}/32')!,
        ],
      ),
      apiKey: 'k1',
    );
    expect(await _post(lan, inside.port, '/serverVersion', apiKey: 'k1'), 200);
  });

  test('仅本机：只绑回环，局域网地址连 TCP 都建立不了', () async {
    final FushiApiServer s = await start(
      FushiApiAccessPolicy.localOnly,
      apiKey: 'k1',
    );
    expect(
      await _post(
        InternetAddress.loopbackIPv4,
        s.port,
        '/serverVersion',
        apiKey: 'k1',
      ),
      200,
    );
    await expectLater(
      _post(lan, s.port, '/serverVersion', apiKey: 'k1'),
      throwsA(isA<SocketException>()),
    );
  });
}
