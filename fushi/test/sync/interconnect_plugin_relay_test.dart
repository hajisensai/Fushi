// 互联「插件中继」（拍板台 wOMR4_Er7s 方案 b）：真 TLS FushiSyncServer + host 替身，client
// 走 InterconnectMusicPluginRelay + MusicPluginManager，媒体经 AppMusicPluginRelayHost 的真实
// 转发（上游是本机回环上的假 CDN，私网判据注入成放行）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_relay_client.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_relay_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_plugin_relay.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:fushi_music/fushi_music.dart';

const String _peer = 'peer-token';

Map<String, Object?> _catalogEntry(String id) => MusicPluginPackageInfo(
  manifest: MusicPluginManifest(
    id: id,
    name: id.toUpperCase(),
    version: '1.0.0',
    api: 1,
    // host 替身故意带上 login：client 也要再去一次。
    capabilities: const <String>['search', 'stream', 'login', 'account'],
    searchTypes: const <String>['song'],
    permissions: const <String>[],
    networkDomains: const <String>['example.com'],
  ),
  digest: 'digest-$id',
  signer: null,
  files: const <String>['main.js'],
).toJson();

/// 只转发媒体、不碰插件管理器的真实 host 实现（上游在回环上，私网判据放行）。
AppMusicPluginRelayHost _forwarder() => AppMusicPluginRelayHost(
  manager: () => throw StateError('不该碰插件管理器'),
  enabled: () async => true,
  isOwnerDevicePeer: (String _) async => true,
  httpClientFactory: HttpClient.new,
  sharedItems: () async => const <String>{},
  resolver: (String _) async => <InternetAddress>[InternetAddress.loopbackIPv4],
  addressBlocker: (InternetAddress _) => false,
);

class _FakeHost implements InterconnectPluginRelayHost {
  _FakeHost(this.upstreamPort);

  final int upstreamPort;
  bool enabled = true;
  Set<String> owners = <String>{_peer};
  final List<String> invoked = <String>[];
  final AppMusicPluginRelayHost forwarder = _forwarder();

  @override
  Future<bool> isPluginRelayEnabled() async => enabled;

  @override
  Future<bool> isOwnerDevicePeer(String peerToken) async =>
      owners.contains(peerToken);

  @override
  Future<List<Map<String, Object?>>> pluginRelayCatalog() async =>
      <Map<String, Object?>>[_catalogEntry('alpha'), _catalogEntry('gone')];

  @override
  Future<Object?> pluginRelayInvoke(
    String pluginId,
    String method,
    Map<String, Object?> args,
  ) async {
    invoked.add('$pluginId.$method');
    if (pluginId == 'gone') {
      throw const InterconnectPluginRelayError(kPluginRelayNotAvailable, '卸了');
    }
    return switch (method) {
      'search' => <String, Object?>{
        'items': <Object?>[
          <String, Object?>{
            'id': 't1',
            'title': '曲 ${args['query']}',
            'coverUrl': 'https://img.example.com/a.jpg',
          },
          <String, Object?>{
            'id': 't2',
            'title': 'B',
            'coverUrl': 'https://evil.example.org/b.jpg',
          },
        ],
        'hasMore': true,
      },
      'stream' => <String, Object?>{
        'url': args['id'] == 'redir'
            ? 'https://cdn.example.com/redir'
            : 'https://cdn.example.com/x.flac',
        'codec': 'flac',
      },
      _ => throw const InterconnectPluginRelayError(kPluginRelayUnsupported),
    };
  }

  @override
  Future<Map<String, String>> pluginRelayCheckCovers(
    String pluginId,
    List<String> urls,
  ) async => <String, String>{
    for (final String u in urls)
      if (u.startsWith('https://img.')) u: u,
  };

  @override
  Future<InterconnectPluginRelayMediaTarget> pluginRelayResolveMedia(
    String pluginId,
    String url,
    Map<String, String> headers,
  ) async => InterconnectPluginRelayMediaTarget(
    pluginId: pluginId,
    // 插件给的地址 → 本机回环上的假 CDN（真实 host 上是插件实例解析过的最终地址）。
    url: 'http://127.0.0.1:$upstreamPort${Uri.parse(url).path}',
    headers: const <String, String>{'referer': 'https://example.com/'},
  );

  @override
  Future<InterconnectPluginRelayUpstream> pluginRelayOpenMedia(
    InterconnectPluginRelayMediaTarget target, {
    String? range,
    required bool head,
  }) => forwarder.pluginRelayOpenMedia(target, range: range, head: head);
}

/// 测试传输：直连真 server（自签证书放行），带 per-peer token。
class _ServerTransport implements MusicPluginRelayTransport {
  _ServerTransport(this.port);

  final int port;
  int requests = 0;

  @override
  Future<List<MusicPluginRelayHostRef>> hosts() async =>
      <MusicPluginRelayHostRef>[(key: 'desk', label: 'Desk')];

  @override
  Future<MusicPluginRelayResponse> send(
    String hostKey,
    String method,
    String path, {
    Object? json,
    required Duration timeout,
  }) async {
    requests++;
    final HttpClient c = HttpClient()
      ..badCertificateCallback = (X509Certificate _, String _, int _) => true;
    try {
      final HttpClientRequest req = await c.openUrl(
        method,
        Uri.parse('https://127.0.0.1:$port$path'),
      );
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('hibiki:$_peer'))}',
      );
      if (json != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(json));
      }
      final HttpClientResponse res = await req.close();
      final String text = await utf8.decodeStream(res);
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        decoded = null;
      }
      return (
        status: res.statusCode,
        json: decoded is Map ? decoded.cast<String, Object?>() : null,
        resolve: (String p) => Uri.parse('https://127.0.0.1:$port$p'),
      );
    } on IOException catch (e) {
      // 与生产传输同一契约：没有 HTTP 回答 = 不可达。
      throw MusicPluginRelayUnreachable('$e');
    } finally {
      c.close(force: true);
    }
  }

  @override
  void close() {}
}

/// 假 CDN：`/x.flac` 是 0..99 共 100 字节、认 Range、带 Set-Cookie；`/redir` 302 走。
Future<HttpServer> _cdn(List<String> seenReferers) async {
  final HttpServer s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final List<int> body = List<int>.generate(100, (int i) => i);
  s.listen((HttpRequest r) async {
    seenReferers.add(r.headers.value('referer') ?? '');
    if (r.uri.path == '/redir') {
      r.response
        ..statusCode = 302
        ..headers.set('location', 'http://10.0.0.1/secret');
      await r.response.close();
      return;
    }
    r.response.headers
      ..set('content-type', 'audio/flac')
      ..set('accept-ranges', 'bytes')
      ..set('set-cookie', 'session=platform-secret');
    final String? range = r.headers.value('range');
    final RegExpMatch? m = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
    if (m != null) {
      final int a = int.parse(m[1]!);
      final int b = int.parse(m[2]!);
      r.response
        ..statusCode = 206
        ..headers.set('content-range', 'bytes $a-$b/100')
        ..contentLength = b - a + 1
        ..add(body.sublist(a, b + 1));
    } else {
      r.response
        ..contentLength = 100
        ..add(body);
    }
    await r.response.close();
  });
  return s;
}

Future<({int status, List<int> body, HttpHeaders headers})> _rawGet(
  String url, {
  String? range,
}) async {
  final HttpClient c = HttpClient()
    ..badCertificateCallback = (X509Certificate _, String _, int _) => true;
  try {
    final HttpClientRequest req = await c.getUrl(Uri.parse(url));
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final HttpClientResponse res = await req.close();
    final List<int> body = <int>[
      for (final List<int> chunk in await res.toList()) ...chunk,
    ];
    return (status: res.statusCode, body: body, headers: res.headers);
  } finally {
    c.close(force: true);
  }
}

void main() {
  late Directory root;
  late HttpServer cdn;
  late List<String> referers;
  late _FakeHost host;
  late FushiSyncServer server;
  late _ServerTransport transport;
  late bool clientEnabled;
  late InterconnectMusicPluginRelay relay;
  late MusicPluginManager manager;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('plugin_relay_');
    referers = <String>[];
    cdn = await _cdn(referers);
    host = _FakeHost(cdn.port);
    final ({String certificatePem, String privateKeyPem}) id =
        FushiSelfSignedCertGenerator.generate(
          commonName: 'fushi-test',
          sanIpAddresses: <String>['127.0.0.1'],
        );
    server =
        FushiSyncServer(
            syncDataDir: '${root.path}/sync',
            port: 0,
            token: 'shared-token',
            allowLan: false,
            securityContext: SecurityContext()
              ..useCertificateChainBytes(utf8.encode(id.certificatePem))
              ..usePrivateKeyBytes(utf8.encode(id.privateKeyPem)),
          )
          ..pairedPeerTokensProvider = (() async => <String>{_peer, 'other'})
          ..pluginRelayHost = host;
    await server.start();
    transport = _ServerTransport(server.port);
    clientEnabled = true;
    relay = InterconnectMusicPluginRelay(
      transport: transport,
      enabled: () async => clientEnabled,
    );
    manager = MusicPluginManager(
      rootDir: Directory('${root.path}/music_plugins'),
      httpClientFactory: HttpClient.new,
      log: (String _, String _, String _) {},
      relay: relay,
    );
  });

  tearDown(() async {
    await manager.dispose();
    relay.dispose();
    await server.stop();
    await cdn.close(force: true);
    root.deleteSync(recursive: true);
  });

  test('host 的插件出现在本机：标出代跑设备、登录能力不出现', () async {
    final List<InstalledMusicPlugin> plugins = await manager.list();
    expect(plugins.map((InstalledMusicPlugin p) => p.id), <String>[
      'alpha',
      'gone',
    ]);
    final InstalledMusicPlugin alpha = plugins.first;
    expect(alpha.relayedVia, 'Desk');
    expect(alpha.isMusicSource, isTrue);
    expect(alpha.info!.manifest.can(MusicPluginCapability.login), isFalse);
    expect(alpha.info!.manifest.can(MusicPluginCapability.search), isTrue);
    // 目录有缓存：再列一次不再发请求。
    final int before = transport.requests;
    await manager.list();
    expect(transport.requests, before);
  });

  test('搜索经 host 代跑；封面只留 host 核对过的', () async {
    final MusicPluginPage<MusicPluginTrack> page = await manager
        .source('alpha')
        .searchTracks('夜');
    expect(page.items.map((MusicPluginTrack t) => t.title), <String>[
      '曲 夜',
      'B',
    ]);
    expect(page.hasMore, isTrue);
    expect(page.items.first.coverUrl, 'https://img.example.com/a.jpg');
    expect(page.items.last.coverUrl, isNull);
    expect(host.invoked, <String>['alpha.search']);
  });

  test('取流拿到流票地址：免 Authorization 取字节，Range 透传，平台 Cookie 不出 host', () async {
    final MusicPluginStream s = await manager.source('alpha').stream('t1');
    expect(s.codec, 'flac');
    expect(s.headers, isEmpty);
    expect(
      s.url,
      startsWith(
        'https://127.0.0.1:${server.port}$kInterconnectPluginRelayStreamPrefix',
      ),
    );

    final ({int status, List<int> body, HttpHeaders headers}) full =
        await _rawGet(s.url);
    expect(full.status, 200);
    expect(full.body, List<int>.generate(100, (int i) => i));
    expect(full.headers.value('content-type'), 'audio/flac');
    expect(full.headers.value('set-cookie'), isNull);
    expect(referers.last, 'https://example.com/', reason: '插件要求的请求头由 host 带上');

    final ({int status, List<int> body, HttpHeaders headers}) part =
        await _rawGet(s.url, range: 'bytes=10-13');
    expect(part.status, 206);
    expect(part.body, <int>[10, 11, 12, 13]);
    expect(part.headers.value('content-range'), 'bytes 10-13/100');

    expect(
      (await _rawGet(
        'https://127.0.0.1:${server.port}${kInterconnectPluginRelayStreamPrefix}forged',
      )).status,
      404,
    );
  });

  test('签发后不再是「我的设备」/ host 关了开关：流票随之失效', () async {
    final MusicPluginStream s = await manager.source('alpha').stream('t1');
    host.owners = <String>{};
    expect((await _rawGet(s.url)).status, 403);
    host.owners = <String>{_peer};
    host.enabled = false;
    expect((await _rawGet(s.url)).status, 403);
    host.enabled = true;
    expect((await _rawGet(s.url)).status, 200);
  });

  test('上游又重定向：不跟、不交出 Location', () async {
    final MusicPluginStream s = await manager.source('alpha').stream('redir');
    final ({int status, List<int> body, HttpHeaders headers}) r = await _rawGet(
      s.url,
    );
    expect(r.status, 502);
    expect(r.headers.value('location'), isNull);
    expect(utf8.decode(r.body), isNot(contains('10.0.0.1')));
  });

  test('host 上插件已不可用：本机报 notInstalled，并通知各列表重列', () async {
    await manager.list();
    final Future<void> changed = manager.changes.first;
    await expectLater(
      manager.source('gone').searchTracks('q'),
      throwsA(
        isA<MusicPluginUnavailableException>().having(
          (MusicPluginUnavailableException e) => e.reason,
          'reason',
          MusicPluginUnavailableReason.notInstalled,
        ),
      ),
    );
    await changed.timeout(const Duration(seconds: 2));
  });

  test('本机不是 host 的「我的设备」：目录为空', () async {
    host.owners = <String>{'other'};
    expect(await manager.list(), isEmpty);
  });

  test('本机「接收共享来源」关着：一个请求都不发', () async {
    clientEnabled = false;
    expect(await manager.list(), isEmpty);
    expect(transport.requests, 0);
  });

  test('读开关 / 配对表抛错：中继按「取不到」处理，不连累本机插件列表', () async {
    final InterconnectMusicPluginRelay broken = InterconnectMusicPluginRelay(
      transport: transport,
      enabled: () async => throw StateError('database closed'),
    );
    addTearDown(broken.dispose);
    expect(await broken.list(), isEmpty);
    final MusicPluginManager m = MusicPluginManager(
      rootDir: Directory('${root.path}/broken_plugins'),
      httpClientFactory: HttpClient.new,
      log: (_, _, _) {},
      relay: broken,
    );
    addTearDown(m.dispose);
    expect(await m.list(), isEmpty);
  });

  test('端点门：共享 token 拒、未装配 404', () async {
    final HttpClient c = HttpClient()
      ..badCertificateCallback = (X509Certificate _, String _, int _) => true;
    try {
      final HttpClientRequest req = await c.getUrl(
        Uri.parse(
          'https://127.0.0.1:${server.port}$kInterconnectPluginRelayPath',
        ),
      );
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('hibiki:shared-token'))}',
      );
      final HttpClientResponse res = await req.close();
      expect(res.statusCode, 403);
      expect(await utf8.decodeStream(res), contains('paired_peer_required'));
    } finally {
      c.close(force: true);
    }
    server.pluginRelayHost = null;
    final MusicPluginRelayResponse off = await transport.send(
      'desk',
      'GET',
      kInterconnectPluginRelayPath,
      timeout: const Duration(seconds: 5),
    );
    expect(off.status, 404);
  });

  test('host 实现：登录能力不代跑（不碰插件管理器）', () async {
    await expectLater(
      _forwarder().pluginRelayInvoke('alpha', 'login', <String, Object?>{
        'op': 'logout',
      }),
      throwsA(
        isA<InterconnectPluginRelayError>().having(
          (InterconnectPluginRelayError e) => e.code,
          'code',
          kPluginRelayUnsupported,
        ),
      ),
    );
  });
}
