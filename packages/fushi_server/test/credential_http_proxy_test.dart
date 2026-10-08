import 'dart:convert';
import 'dart:io';

import 'package:fushi_server/src/commands/sync_commands.dart';
import 'package:fushi_server/src/credential_http_proxy.dart';
import 'package:fushi_server/src/ctl/admin_client.dart';
import 'package:test/test.dart';

/// 环境里「设了代理」：所有经 [HttpClient.findProxyFromEnvironment] 的请求都指向假代理。
class _EnvProxy extends HttpOverrides {
  _EnvProxy(this.directive);

  final String directive;

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) => directive;
}

/// 带凭据的 CLI 客户端（ctl 的 admin_token、sync 的 host token）不得把请求交给环境代理：
/// dart:io 的 HttpClient 缺省读 HTTP(S)_PROXY，且不给回环开例外。
void main() {
  late HttpServer proxy;
  late HttpServer target;
  late List<String> proxySaw;
  late List<String?> targetAuth;

  setUp(() async {
    proxySaw = <String>[];
    targetAuth = <String?>[];
    proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    proxy.listen((HttpRequest r) async {
      proxySaw.add('${r.method} ${r.uri} auth=${r.headers.value(HttpHeaders.authorizationHeader)}');
      r.response.statusCode = HttpStatus.badGateway;
      await r.response.close();
    });
    target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((HttpRequest r) async {
      targetAuth.add(r.headers.value(HttpHeaders.authorizationHeader));
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode(<String, Object?>{'ok': true}));
      await r.response.close();
    });
  });

  tearDown(() async {
    await proxy.close(force: true);
    await target.close(force: true);
  });

  String proxyDirective() => 'PROXY 127.0.0.1:${proxy.port}';

  test('ctl：admin API 在回环上，设了环境代理也直连，token 不进代理', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final AdminClient client = AdminClient(baseUri: Uri.parse('http://127.0.0.1:${target.port}'), token: 'secret');
      try {
        expect(await client.get('/api/admin/status'), <String, Object?>{'ok': true});
      } finally {
        client.close();
      }
    }, _EnvProxy(proxyDirective()));
    expect(proxySaw, isEmpty);
    expect(targetAuth, <String?>['Bearer secret']);
  });

  test('sync：明文 http host 直连，host token 不进代理', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final HttpAggregateRemote remote = HttpAggregateRemote(
        baseUrl: Uri.parse('http://127.0.0.1:${target.port}'),
        token: 'host-token',
      );
      try {
        expect(await remote.fetch(), <String, Object?>{'ok': true});
      } finally {
        remote.close();
      }
    }, _EnvProxy(proxyDirective()));
    expect(proxySaw, isEmpty);
    expect(targetAuth.single, startsWith('Basic '));
  });

  test('策略：回环 / 明文恒直连，https 远端跟随环境代理（CONNECT 隧道读不到凭据）', () {
    HttpOverrides.runWithHttpOverrides(() {
      expect(credentialProxyFor(Uri.parse('http://nas.lan:38780/api/admin/status')), 'DIRECT');
      expect(credentialProxyFor(Uri.parse('http://192.168.1.5:38780/')), 'DIRECT');
      expect(credentialProxyFor(Uri.parse('https://localhost:38780/')), 'DIRECT');
      expect(credentialProxyFor(Uri.parse('https://127.0.0.1:38780/')), 'DIRECT');
      expect(credentialProxyFor(Uri.parse('https://[::1]:38780/')), 'DIRECT');
      expect(credentialProxyFor(Uri.parse('https://nas.example.com:38780/')), 'PROXY 127.0.0.1:9');
    }, _EnvProxy('PROXY 127.0.0.1:9'));
  });
}
