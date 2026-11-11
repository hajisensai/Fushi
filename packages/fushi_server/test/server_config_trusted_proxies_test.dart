import 'package:fushi_server/src/config/server_config.dart';
import 'package:test/test.dart';

/// BUG-4390：`trusted_proxies` 配置键。
void main() {
  test('缺省为空列表', () {
    final ServerConfig c = ServerConfig.parse(
      'data_dir: "/srv/fushi/data"\n',
      configDir: '/etc/fushi',
    );
    expect(c.trustedProxies, isEmpty);
    expect(c.toYaml(), contains('trusted_proxies: []'));
  });

  test('toYaml → parse 往返一致', () {
    final ServerConfig a = ServerConfig.defaults(
      dataDir: '/srv/fushi/data',
    ).copyWith(trustedProxies: <String>['127.0.0.1', '10.0.0.0/8', '::1']);
    final ServerConfig b = ServerConfig.parse(
      a.toYaml(),
      configDir: '/etc/fushi',
    );
    expect(b.trustedProxies, <String>['127.0.0.1', '10.0.0.0/8', '::1']);
  });

  test('非法条目拒绝加载并点名那一项', () {
    expect(
      () => ServerConfig.parse(
        'data_dir: "/srv/fushi/data"\n'
        'trusted_proxies:\n'
        '  - "127.0.0.1"\n'
        '  - "proxy.lan"\n',
        configDir: '/etc/fushi',
      ),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          allOf(contains('trusted_proxies'), contains('proxy.lan')),
        ),
      ),
    );
    expect(
      () => ServerConfig.parse(
        'data_dir: "/srv/fushi/data"\n'
        'trusted_proxies: ["10.0.0.0/40"]\n',
        configDir: '/etc/fushi',
      ),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('10.0.0.0/40'),
        ),
      ),
    );
  });
}
