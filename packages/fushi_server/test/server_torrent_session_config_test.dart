// BUG-5071：`torrent:` 段的内置引擎会话设置（上传开关 / 限速 / 活跃名额 / 做种上限）
// 经 yaml、admin API（WebUI「设置」页 / `ctl settings set`）读写，保存即推进 host
// 实时配置、不进「需重启」清单。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/config/server_torrent_session_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';
import 'support/fake_rwkv.dart';

void main() {
  group('yaml', () {
    test('缺省：上传关、限速不限、同时下载数不限，其余取 libtorrent 默认', () {
      final ServerConfig c = ServerConfig.parse(
        'port: 1\n',
        configDir: '/etc/fushi',
      );
      const ServerTorrentSessionConfig d = ServerTorrentSessionConfig();
      expect(c.torrentSession, d);
      expect(d.uploadEnabled, isFalse);
      expect(d.uploadLimitKbps, 0);
      expect(d.downloadLimitKbps, 0);
      expect(d.maxActiveDownloads, QbConnectionConfig.activeLimitUnlimited);
      expect(d.maxActiveSeeds, 0);
      expect(d.seedRatioLimit, 0);
    });

    test('写回 → 读回逐项一致（snake_case 键，与 engine / listen 同段）', () {
      final ServerConfig a = ServerConfig.defaults(dataDir: '/srv/d').copyWith(
        torrentPeerRoots: <String>['/mnt/share'],
        torrentSession: const ServerTorrentSessionConfig(
          uploadEnabled: true,
          uploadLimitKbps: 100,
          downloadLimitKbps: 5000,
          limitLocalPeers: true,
          maxActiveDownloads: 10,
          maxActiveSeeds: -1,
          maxConnections: 200,
          seedRatioLimit: 1.5,
          seedTimeLimitMinutes: 120,
        ),
      );
      final String yaml = a.toYaml();
      expect(yaml, contains('torrent:\n'));
      expect(yaml, contains('  upload_enabled: true\n'));
      expect(yaml, contains('  upload_limit_kbps: 100\n'));
      expect(yaml, contains('  max_active_downloads: 10\n'));
      expect(yaml, contains('  seed_ratio_limit: 1.5\n'));
      final ServerConfig b = ServerConfig.parse(yaml, configDir: '/etc/fushi');
      expect(b.torrentSession, a.torrentSession);
      expect(b.torrentPeerRoots, <String>['/mnt/share']);
      expect(b.torrentListen, a.torrentListen);

      // 默认值也全量写出、读回不漂。
      final ServerConfig d = ServerConfig.defaults(dataDir: '/srv/d');
      expect(
        ServerConfig.parse(d.toYaml(), configDir: '/etc').torrentSession,
        const ServerTorrentSessionConfig(),
      );
    });

    test('手写 yaml：整数写法的分享率可读；非法值拒绝启动并点名键', () {
      expect(
        ServerConfig.parse(
          'torrent:\n  seed_ratio_limit: 2\n  upload_enabled: "true"\n',
          configDir: '/etc',
        ).torrentSession,
        const ServerTorrentSessionConfig(
          seedRatioLimit: 2,
          uploadEnabled: true,
        ),
      );
      for (final String bad in <String>[
        'torrent:\n  upload_limit_kbps: -5\n',
        'torrent:\n  max_active_downloads: -2\n',
        'torrent:\n  seed_ratio_limit: -1\n',
        'torrent:\n  upload_enabled: maybe\n',
        'torrent:\n  max_connections: lots\n',
      ]) {
        expect(
          () => ServerConfig.parse(bad, configDir: '/etc'),
          throwsA(
            isA<FormatException>().having(
              (FormatException e) => e.message,
              'message',
              contains('torrent.'),
            ),
          ),
          reason: bad,
        );
      }
    });

    test('applyTo 只覆盖会话设置这几项，其余保持引擎配置原值', () {
      const QbConnectionConfig base = QbConnectionConfig(
        backend: QbConnectionConfig.backendEmbedded,
        listenPort: 7000,
        enableDht: false,
      );
      final QbConnectionConfig c = const ServerTorrentSessionConfig(
        uploadEnabled: true,
        uploadLimitKbps: 100,
        seedTimeLimitMinutes: 30,
      ).applyTo(base);
      expect(c.backend, QbConnectionConfig.backendEmbedded);
      expect(c.listenPort, 7000);
      expect(c.enableDht, isFalse);
      expect(c.uploadEnabled, isTrue);
      expect(c.uploadLimitKbps, 100);
      expect(c.seedTimeLimitMinutes, 30);
      expect(c.maxActiveDownloads, QbConnectionConfig.activeLimitUnlimited);
    });
  });

  group('admin API', () {
    late Directory tmp;
    late FushiDatabase db;
    late File configFile;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_admin_torrent_');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    });

    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    Future<({AdminApi api, AdminContext ctx, HeadlessHost host})>
    build() async {
      final ServerConfig config = ServerConfig.defaults(
        dataDir: p.join(tmp.path, 'data'),
      ).copyWith(adminToken: 'tok');
      await config.save(configFile);
      final ServerPrefs prefs = ServerPrefs(db);
      final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
      final ServerPaths paths = ServerPaths(config.dataDir);
      final HeadlessHost host = HeadlessHost(
        srsRwkvHttpClient: noNetworkHttpClient,
        config: config,
        paths: paths,
        db: db,
        prefs: prefs,
        identity: identity,
        p2pAvailable: () => false,
      );
      final AdminContext ctx = AdminContext(
        config: config,
        configFile: configFile,
        paths: paths,
        log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
        db: db,
        identity: identity,
        host: host,
        startedAt: DateTime.now(),
      );
      return (api: AdminApi(ctx), ctx: ctx, host: host);
    }

    Future<({int status, Map<String, dynamic> json})> call(
      AdminApi api,
      String method,
      String path, [
      Object? body,
    ]) async {
      final shelf.Response r = await api.handle(
        shelf.Request(
          method,
          Uri.parse('http://localhost/api/admin/$path'),
          body: body == null ? null : jsonEncode(body),
        ),
      );
      final Object? decoded = jsonDecode(await r.readAsString());
      return (
        status: r.statusCode,
        json: Map<String, dynamic>.from(decoded! as Map),
      );
    }

    test('GET：torrent 段带会话设置；只有 engine / library / listen 需重启', () async {
      final (:AdminApi api, ctx: _, host: _) = await build();
      final (:int status, :Map<String, dynamic> json) = await call(
        api,
        'GET',
        'settings',
      );
      expect(status, 200);
      final Map<String, dynamic> torrent = Map<String, dynamic>.from(
        json['torrent'] as Map,
      );
      expect(torrent['uploadEnabled'], isFalse);
      expect(torrent['uploadLimitKbps'], 0);
      expect(torrent['maxActiveDownloads'], -1);
      expect(torrent['seedRatioLimit'], 0);
      final List<Object?> restart = json['restartRequiredKeys'] as List;
      expect(
        restart,
        containsAll(<String>[
          'torrent.engine',
          'torrent.library',
          'torrent.listen',
        ]),
      );
      expect(restart, isNot(contains('torrent')));
      expect(restart, isNot(contains('torrent.uploadEnabled')));
    });

    test('PUT 增量改 → 写回 yaml 并推进 host 实时配置；缺省键不改', () async {
      final (:AdminApi api, :AdminContext ctx, :HeadlessHost host) =
          await build();
      final (:int status, :Map<String, dynamic> json) = await call(
        api,
        'PUT',
        'settings',
        <String, Object?>{
          'torrent': <String, Object?>{
            'uploadLimitKbps': 100,
            'maxActiveDownloads': 8,
            'seedRatioLimit': 1.5,
          },
        },
      );
      expect(status, 200, reason: '$json');
      const ServerTorrentSessionConfig want = ServerTorrentSessionConfig(
        uploadLimitKbps: 100,
        maxActiveDownloads: 8,
        seedRatioLimit: 1.5,
      );
      expect(ctx.config.torrentSession, want);
      expect(host.config.torrentSession, want, reason: '下载宿主现读 host.config');
      expect((await ServerConfig.load(configFile)).torrentSession, want);
      expect((json['torrent'] as Map)['uploadLimitKbps'], 100);

      // 只改 engine：会话设置原样保留。
      await call(api, 'PUT', 'settings', <String, Object?>{
        'torrent': <String, Object?>{'engine': 'auto'},
      });
      expect(host.config.torrentSession, want);
    });

    test('类型 / 取值不对 → 400，不落盘', () async {
      final (:AdminApi api, ctx: _, :HeadlessHost host) = await build();
      for (final Map<String, Object?> torrent in <Map<String, Object?>>[
        <String, Object?>{'uploadEnabled': 'yes'},
        <String, Object?>{'uploadLimitKbps': -1},
        <String, Object?>{'uploadLimitKbps': 1.5},
        <String, Object?>{'maxActiveSeeds': -3},
        <String, Object?>{'seedRatioLimit': -0.5},
      ]) {
        final (:int status, json: _) = await call(
          api,
          'PUT',
          'settings',
          <String, Object?>{'torrent': torrent},
        );
        expect(status, 400, reason: '$torrent');
      }
      expect(host.config.torrentSession, const ServerTorrentSessionConfig());
      expect(
        (await ServerConfig.load(configFile)).torrentSession,
        const ServerTorrentSessionConfig(),
      );
    });
  });
}
