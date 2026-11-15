import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// 未带 key、正文按 chunked 分块流式发送 [totalBytes]（不一次性占内存）。返回
/// 读到的响应状态码（读不到为 null）与发完前服务端是否已断开连接。服务端整读正文时
/// 要等全部发完才会回 401。
Future<({int? status, bool cutOffEarly})> _postChunkedWithoutKey(
  int port,
  String path, {
  required int totalBytes,
  String? authorization,
}) async {
  final Socket socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
  );
  final Completer<int?> status = Completer<int?>();
  final BytesBuilder received = BytesBuilder();
  socket.listen(
    (Uint8List data) {
      received.add(data);
      final RegExpMatch? m = RegExp(
        r'^HTTP/1\.1 (\d{3})',
      ).firstMatch(latin1.decode(received.toBytes()));
      if (m != null && !status.isCompleted) {
        status.complete(int.parse(m.group(1)!));
      }
    },
    onError: (Object _) {},
    onDone: () {
      if (!status.isCompleted) status.complete(null);
    },
  );
  socket.add(
    latin1.encode(
      'POST $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\n'
      'Content-Type: application/json\r\n'
      '${authorization == null ? '' : 'Authorization: $authorization\r\n'}'
      'Transfer-Encoding: chunked\r\n\r\n',
    ),
  );
  const int chunkSize = 256 * 1024;
  final Uint8List chunk = Uint8List(chunkSize)..fillRange(0, chunkSize, 0x20);
  final List<int> chunkHead = latin1.encode(
    '${chunkSize.toRadixString(16)}\r\n',
  );
  final List<int> crlf = latin1.encode('\r\n');
  bool sentAll = false;
  try {
    for (int sent = 0; sent < totalBytes && !status.isCompleted;) {
      socket
        ..add(chunkHead)
        ..add(chunk)
        ..add(crlf);
      await socket.flush();
      sent += chunkSize;
    }
    if (!status.isCompleted) {
      socket.add(latin1.encode('0\r\n\r\n'));
      await socket.flush();
      sentAll = true;
    }
  } on Object {
    // 服务端回完 413 后断开：写端报错。
  }
  try {
    final int? code = await status.future.timeout(const Duration(seconds: 20));
    return (status: code, cutOffEarly: !sentAll);
  } finally {
    socket.destroy();
  }
}

/// 未带 header / query key，把 key 放在 JSON body 里（yomitan-api 兼容路径）。
Future<int> _postBodyKey(int port, String path, String key) async {
  final HttpClient client = HttpClient()..findProxy = (Uri _) => 'DIRECT';
  try {
    final HttpClientRequest req = await client.open(
      'POST',
      InternetAddress.loopbackIPv4.address,
      port,
      path,
    );
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(<String, Object?>{'key': key, 'pad': 'p' * 4096}));
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

  test('未带 key 发 70 MiB chunked 正文 → 413，鉴权失败分支不整读正文', () async {
    final FushiApiServer s = await start(lanPolicy, apiKey: 'k1');
    final ({int? status, bool cutOffEarly}) r = await _postChunkedWithoutKey(
      s.port,
      '/api/lookup/dictionary',
      totalBytes: 70 * 1024 * 1024,
    );
    // 服务端读满 64 KiB 就回 413 并关连接。客户端还在猛发时，有的平台（macOS）
    // 关连接的 RST 会冲掉对端尚未读到的 413——那时至少要看到「没发完就被断开」。
    // 修复前服务端整读 70 MiB 后回 401，两条都不成立。
    expect(
      r.status == 413 || (r.status == null && r.cutOffEarly),
      isTrue,
      reason: 'status=${r.status} cutOffEarly=${r.cutOffEarly}',
    );
  });

  test('Basic 头里 key 过期 + 正文超过 64 KiB → 401（不是 413）', () async {
    // 评审 compat-1：浏览器扩展只在 401 时重读自动配置、换新 key 重试；回 413 会让
    // 带截图的制卡请求直接失败。凭据已在头里给出（只是不对）就是鉴权失败。
    final FushiApiServer s = await start(lanPolicy, apiKey: 'k1');
    final ({int? status, bool cutOffEarly}) r = await _postChunkedWithoutKey(
      s.port,
      '/api/mine',
      totalBytes: 1024 * 1024,
      authorization: 'Basic ${base64Encode(utf8.encode('fushi:stale-key'))}',
    );
    // 服务端读满 64 KiB 就回应并关连接；读不到状态行时（macOS 上 RST 冲掉响应）
    // 至少要看到没发完就被断开。修复前读得到状态行时是 413。
    expect(
      r.status == 401 || (r.status == null && r.cutOffEarly),
      isTrue,
      reason: 'status=${r.status} cutOffEarly=${r.cutOffEarly}',
    );
  });

  test('未带 header key、body 里带正确 key（< 64 KiB）→ 照常放行', () async {
    final FushiApiServer s = await start(lanPolicy, apiKey: 'k1');
    expect(await _postBodyKey(s.port, '/serverVersion', 'k1'), 200);
    expect(await _postBodyKey(s.port, '/serverVersion', 'wrong'), 401);
  });
}
