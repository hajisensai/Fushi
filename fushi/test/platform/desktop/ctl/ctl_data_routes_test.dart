import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/sync/sync_backend_type.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_data_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_data_wire.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart'
    show JellyfinServerConfig;
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:path/path.dart' as p;

/// 路由表构造期不读 ref（全部在处理器闭包里才读），给个占位即可。
class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('构造路由表时不应访问 ref');
}

void main() {
  final List<CtlRoute> routes = buildDataCtlRoutes(
    DesktopCtlContext(ref: _UnusedRef(), focusMainWindow: () async {}),
  );

  group('路由表', () {
    test('全部在 /api/admin/ 下，method + path 不重复', () {
      expect(routes, isNotEmpty);
      final Set<String> seen = <String>{};
      for (final CtlRoute r in routes) {
        expect(r.pattern, startsWith('/api/admin/'));
        expect(seen.add('${r.method} ${r.pattern}'), isTrue, reason: r.pattern);
      }
    });

    test('CLI 用到的每个 method + path 都有路由接住', () {
      final List<(String, String)> calls = <(String, String)>[
        ('GET', '/api/admin/backups'),
        ('GET', '/api/admin/backups/info'),
        ('POST', '/api/admin/backups'),
        ('POST', '/api/admin/backups/restore'),
        ('GET', '/api/admin/sync'),
        ('POST', '/api/admin/sync/run'),
        ('GET', '/api/admin/downloads'),
        ('GET', '/api/admin/downloads/j1'),
        ('POST', '/api/admin/downloads'),
        ('POST', '/api/admin/downloads/j1/cancel'),
        ('POST', '/api/admin/downloads/j1/retry'),
        ('DELETE', '/api/admin/downloads/j1'),
        ('GET', '/api/admin/media-servers'),
        ('GET', '/api/admin/media-servers/jellyfin%3Ahttp%3A%2F%2Fh/items'),
        ('GET', '/api/admin/media-servers/1/search'),
        ('GET', '/api/admin/peers'),
        ('GET', '/api/admin/peers/host'),
        ('POST', '/api/admin/peers/host/start'),
        ('POST', '/api/admin/peers/host/stop'),
        ('POST', '/api/admin/peers/pair'),
        ('GET', '/api/admin/storage/root'),
        ('GET', '/api/admin/storage/usage'),
      ];
      for (final (String method, String path) in calls) {
        final List<CtlRoute> hits = <CtlRoute>[
          for (final CtlRoute r in routes)
            if (r.method == method && r.match(path) != null) r,
        ];
        expect(hits, hasLength(1), reason: '$method $path');
      }
    });

    test('媒体服务器 id 路径参数按段解码', () {
      final CtlRoute r = routes.firstWhere(
        (CtlRoute r) => r.pattern == '/api/admin/media-servers/:id/items',
      );
      expect(
        r.match('/api/admin/media-servers/jellyfin%3Ahttp%3A%2F%2Fh%2Fu/items'),
        <String, String>{'id': 'jellyfin:http://h/u'},
      );
    });

    test('破坏性路由缺 confirm 直接 400，不碰 app', () async {
      final CtlRoute restore = routes.firstWhere(
        (CtlRoute r) => r.pattern == '/api/admin/backups/restore',
      );
      await expectLater(
        restore.handler(
          const CtlCall(
            method: 'POST',
            path: '/api/admin/backups/restore',
            body: <String, Object?>{'path': '/x.zip'},
          ),
        ),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
        ),
      );
    });
  });

  group('凭据不出终端', () {
    test('redactCtlSecrets 抹掉查询参数与 Authorization 里的令牌', () {
      final String out = redactCtlSecrets(
        'GET http://h/Items?api_key=abc123&x=1 failed; '
        'X-Plex-Token=zzz; Authorization: Bearer eyJ.abc-def',
      );
      expect(out, isNot(contains('abc123')));
      expect(out, isNot(contains('zzz')));
      expect(out, isNot(contains('eyJ.abc-def')));
      expect(out, contains('api_key=***'));
      expect(out, contains('x=1'));
    });

    test('peerHostUrlToWire 只报有没有令牌 / 指纹', () {
      final Map<String, Object?> wire = peerHostUrlToWire(
        const FushiClientUrl(
          url: 'https://192.168.1.2:7000',
          token: 'secret-token',
          fingerprintSha256: 'ab:cd',
          deviceName: 'PC',
          hostId: 'h1',
        ),
      );
      expect(wire.values, isNot(contains('secret-token')));
      expect(wire.values, isNot(contains('ab:cd')));
      expect(wire['paired'], isTrue);
      expect(wire['pinned'], isTrue);
      expect(wire['deviceName'], 'PC');
    });

    test('媒体服务器配置只出地址与用户名，不出令牌', () {
      final MediaServerConfig config = JellyfinServerConfig(
        serverUrl: 'http://media.local:8096',
        username: 'alice',
        userId: 'u1',
        accessToken: 'tok-123',
      );
      final Map<String, Object?> wire = mediaServerConfigToWire(
        config,
        index: 1,
      );
      expect(wire.toString(), isNot(contains('tok-123')));
      expect(wire['index'], 1);
      expect(wire['account'], 'alice');
      expect(wire['kind'], 'jellyfin');
    });

    test('syncBackendToWire 只有状态位', () {
      expect(
        syncBackendToWire(
          type: SyncBackendType.webDav,
          selected: true,
          configured: false,
        ),
        <String, Object?>{
          'id': 'webDav',
          'selected': true,
          'configured': false,
        },
      );
    });
  });

  group('参数解析', () {
    test('parseBackupCategories：空 → null，逗号分隔，未知名 400', () {
      expect(parseBackupCategories(const <String>[]), isNull);
      expect(
        parseBackupCategories(const <String>['books, fonts', 'games']),
        <BackupCategory>{
          BackupCategory.books,
          BackupCategory.fonts,
          BackupCategory.games,
        },
      );
      expect(
        () => parseBackupCategories(const <String>['nope']),
        throwsA(isA<CtlFailure>()),
      );
    });

    test('resolveBackupOutputPath：目录接默认文件名，相对路径拒绝', () {
      final String dir = p.join(p.separator, 'tmp', 'out');
      expect(
        resolveBackupOutputPath(
          dir,
          isDirectory: true,
          defaultFilename: 'fushi-backup-1.fushi.zip',
        ),
        p.join(dir, 'fushi-backup-1.fushi.zip'),
      );
      expect(
        resolveBackupOutputPath(
          p.join(dir, 'a.zip'),
          isDirectory: false,
          defaultFilename: 'x',
        ),
        p.join(dir, 'a.zip'),
      );
      expect(
        () => resolveBackupOutputPath(
          'rel.zip',
          isDirectory: false,
          defaultFilename: 'x',
        ),
        throwsA(isA<CtlFailure>()),
      );
    });

    test('classifyDownloadTarget / magnetTaskTitle', () {
      expect(
        classifyDownloadTarget('magnet:?xt=urn:btih:abc'),
        CtlDownloadTargetKind.magnet,
      );
      expect(
        classifyDownloadTarget('/a/b.TORRENT'),
        CtlDownloadTargetKind.torrentFile,
      );
      expect(
        classifyDownloadTarget('https://x/y.torrent'),
        CtlDownloadTargetKind.url,
      );
      expect(
        () => classifyDownloadTarget('/a/b.mkv'),
        throwsA(isA<CtlFailure>()),
      );
      expect(
        magnetTaskTitle('magnet:?xt=urn:btih:a&dn=Foo%20Bar', null),
        'Foo Bar',
      );
      expect(magnetTaskTitle('magnet:?xt=urn:btih:a&dn=Foo', ' T '), 'T');
      expect(magnetTaskTitle('magnet:?xt=urn:btih:a', null), isNull);
    });

    test('resolveMediaServerConfig：序号或 sourceId，找不到 404', () {
      final List<MediaServerConfig> configs = <MediaServerConfig>[
        JellyfinServerConfig(
          serverUrl: 'http://a:8096',
          username: 'u',
          userId: 'u1',
          accessToken: 't',
        ),
        JellyfinServerConfig(
          serverUrl: 'http://b:8096',
          username: 'u',
          userId: 'u2',
          accessToken: 't',
        ),
      ];
      expect(resolveMediaServerConfig(configs, '2'), same(configs[1]));
      expect(
        resolveMediaServerConfig(configs, configs[0].sourceId),
        same(configs[0]),
      );
      expect(
        () => resolveMediaServerConfig(configs, '3'),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
        ),
      );
    });
  });

  group('出参', () {
    test('mediaServerPageToWire 带翻页信息', () {
      final Map<String, Object?> wire = mediaServerPageToWire(
        const MediaServerPage(
          items: <MediaServerItem>[
            MediaServerItem(
              id: 'e1',
              name: 'Ep',
              type: MediaServerItemType.episode,
              seriesName: 'S',
              seasonNumber: 1,
              episodeNumber: 2,
            ),
          ],
          totalCount: 10,
          startIndex: 0,
        ),
      );
      expect(wire['hasMore'], isTrue);
      expect(wire['nextStartIndex'], 1);
      final Map<String, Object?> item =
          (wire['items']! as List<Object?>).single! as Map<String, Object?>;
      expect(item['episode'], 'S01E02');
      expect(item['playable'], isTrue);
    });

    test('syncOutcomeToWire', () {
      expect(syncOutcomeToWire(null), isNull);
      expect(
        syncOutcomeToWire(
          const SyncRunOutcome(
            kind: SyncActivityKind.fullSweep,
            reason: SyncOutcomeReason.completed,
            channelsRun: 2,
            finishedAt: 5,
          ),
        ),
        <String, Object?>{
          'kind': 'fullSweep',
          'reason': 'completed',
          'channelsRun': 2,
          'finishedAt': 5,
        },
      );
    });
  });
}
