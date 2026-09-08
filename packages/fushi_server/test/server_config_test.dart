import 'package:fushi_server/src/config/server_config.dart';
import 'package:test/test.dart';

void main() {
  test('默认值 → toYaml → parse 往返一致', () {
    final ServerConfig a = ServerConfig.defaults(dataDir: '/srv/fushi/data').copyWith(
      adminToken: 'tok',
      qbittorrentUrl: 'http://qb:8080',
      qbittorrentUsername: 'admin',
      qbittorrentPassword: 'p"w\\d',
      libraries: const <LibraryRootConfig>[
        LibraryRootConfig(id: 'anime', path: '/srv/media/anime'),
        LibraryRootConfig(id: 'books', path: '/srv/media/books', kind: 'book', enabled: false),
      ],
      adminPort: 9000,
      adminBind: '127.0.0.1',
    );
    final ServerConfig b = ServerConfig.parse(a.toYaml(), configDir: '/etc/fushi');
    expect(b.dataDir, a.dataDir);
    expect(b.port, a.port);
    expect(b.adminPort, 9000);
    expect(b.adminBind, '127.0.0.1');
    expect(b.adminToken, 'tok');
    expect(b.qbittorrentUrl, 'http://qb:8080');
    expect(b.qbittorrentPassword, 'p"w\\d');
    expect(b.libraries.map((LibraryRootConfig l) => l.id), <String>['anime', 'books']);
    expect(b.libraries[1].kind, 'book');
    expect(b.libraries[1].enabled, isFalse);
  });

  test('缺项取默认，相对 data_dir 按配置目录解析', () {
    final ServerConfig c = ServerConfig.parse('port: 1234\n', configDir: '/etc/fushi');
    expect(c.port, 1234);
    expect(c.adminPort, ServerConfig.defaultAdminPort);
    expect(c.tls, isTrue);
    expect(c.lanRequiresPin, isTrue);
    expect(c.dataDir.replaceAll('\\', '/'), endsWith('/etc/fushi/data'));
  });
}
