import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/sync/sync_backend_type.dart';
import 'package:fushi/src/media/discovery/direct_link_download.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_data_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_data_wire.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart'
    show JellyfinServerConfig;
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart'
    show SyncAssetChannelScope, SyncChannel;
import 'package:fushi/src/sync/sync_backend.dart' show SyncBackend;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show
        BackupImportMode,
        BackupImportPreset,
        backupImportCategoriesFor,
        backupImportPresetCategories,
        importSelectableCategories;
import 'package:path/path.dart' as p;

/// 只用来造 [SyncChannel]，任何成员被碰到就是测试假设错了。
class _NoBackend implements SyncBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected ${invocation.memberName}');
}

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
        ('GET', '/api/admin/downloads/direct%3A3'),
        ('POST', '/api/admin/downloads/direct%3A3/cancel'),
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

  group('第二轮：参数先于 app 校验', () {
    Future<void> expect400(String pattern, Map<String, Object?> body) =>
        expectLater(
          routes
              .firstWhere(
                (CtlRoute r) => r.pattern == pattern && r.method == 'POST',
              )
              .handler(CtlCall(method: 'POST', path: pattern, body: body)),
          throwsA(
            isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
          ),
        );

    test('sync run 未知通道名 400', () async {
      await expect400('/api/admin/sync/run', <String, Object?>{
        'channels': <String>['webDav'],
      });
    });

    test('backup restore 未知模式 / 非法组合 400', () async {
      await expect400('/api/admin/backups/restore', <String, Object?>{
        'path': '/x.zip',
        'confirm': true,
        'mode': 'nuke',
      });
      await expect400('/api/admin/backups/restore', <String, Object?>{
        'path': '/x.zip',
        'confirm': true,
        'categories': <String>['books'],
      });
    });
  });

  group('sync run 通道', () {
    test('parseSyncChannelScopes：空 → null（全部通道），逗号分隔，未知 400', () {
      expect(parseSyncChannelScopes(const <String>[]), isNull);
      expect(
        parseSyncChannelScopes(const <String>['cloud, interconnect']),
        <SyncAssetChannelScope>{
          SyncAssetChannelScope.cloud,
          SyncAssetChannelScope.interconnect,
        },
      );
      expect(
        () => parseSyncChannelScopes(const <String>['webDav']),
        throwsA(isA<CtlFailure>()),
      );
    });

    test('syncChannelToWire 出通道名与后端名，不出后端实例', () {
      expect(
        syncChannelToWire(
          SyncChannel(
            _NoBackend(),
            type: SyncBackendType.webDav,
            isInterconnect: false,
          ),
        ),
        <String, Object?>{'id': 'cloud', 'backend': 'webDav'},
      );
      expect(
        syncChannelToWire(
          SyncChannel(
            _NoBackend(),
            type: SyncBackendType.fushiServer,
            isInterconnect: true,
          ),
        )['id'],
        'interconnect',
      );
    });
  });

  group('backup restore 预设', () {
    test('没给模式 → null（走 app 确认框）', () {
      expect(
        parseBackupImportPreset(
          mode: null,
          categories: const <String>[],
          importSettings: false,
        ),
        isNull,
      );
    });

    test('merge / replace 与分类、设置开关', () {
      final BackupImportPreset merge = parseBackupImportPreset(
        mode: 'merge',
        categories: const <String>['books,fonts'],
        importSettings: false,
      )!;
      expect(merge.mode, BackupImportMode.merge);
      expect(merge.categories, <BackupCategory>{
        BackupCategory.books,
        BackupCategory.fonts,
      });
      final BackupImportPreset replace = parseBackupImportPreset(
        mode: 'replace',
        categories: const <String>[],
        importSettings: true,
      )!;
      expect(replace.mode, BackupImportMode.overwrite);
      expect(replace.categories, isNull);
      expect(replace.importSettings, isTrue);
    });

    test('合并带 --import-settings、挑恒恢复分类都 400', () {
      expect(
        () => parseBackupImportPreset(
          mode: 'merge',
          categories: const <String>[],
          importSettings: true,
        ),
        throwsA(isA<CtlFailure>()),
      );
      final BackupCategory fixed = BackupCategory.values.firstWhere(
        (BackupCategory c) => !importSelectableCategories.contains(c),
      );
      expect(
        () => parseBackupImportPreset(
          mode: 'replace',
          categories: <String>[fixed.name],
          importSettings: false,
        ),
        throwsA(isA<CtlFailure>()),
      );
    });

    test('预设分类与确认框同一规则：只保留备份里有的可勾选分类', () {
      const BackupContentSummary summary = BackupContentSummary(
        present: <BackupCategory>{BackupCategory.books, BackupCategory.fonts},
      );
      // null 预设 = 确认框默认（备份里有的全勾）。
      expect(
        backupImportPresetCategories(
          const BackupImportPreset(mode: BackupImportMode.overwrite),
          summary,
        ),
        backupImportCategoriesFor(BackupImportMode.overwrite, <BackupCategory>{
          BackupCategory.books,
          BackupCategory.fonts,
        }),
      );
      // 只勾 books：fonts 被去掉；备份里没有的 games 即便点名也不选。
      final Set<BackupCategory> picked = backupImportPresetCategories(
        const BackupImportPreset(
          mode: BackupImportMode.merge,
          categories: <BackupCategory>{
            BackupCategory.books,
            BackupCategory.games,
          },
        ),
        summary,
      );
      expect(picked, contains(BackupCategory.books));
      expect(picked, isNot(contains(BackupCategory.fonts)));
      expect(picked, isNot(contains(BackupCategory.games)));
      for (final BackupCategory c in BackupCategory.values) {
        if (!importSelectableCategories.contains(c)) {
          expect(picked, contains(c), reason: '不可勾选的 ${c.name} 恒恢复');
        }
      }
    });
  });

  group('dl add 直链', () {
    test('任务 id 前缀与内容类型解析', () {
      expect(parseDirectDownloadTaskId('direct:12'), 12);
      expect(parseDirectDownloadTaskId('j1'), isNull);
      expect(parseDirectDownloadTaskId('direct:x'), isNull);
      expect(parseDirectDownloadKind('game'), DiscoveryMediaKind.game);
      expect(() => parseDirectDownloadKind(null), throwsA(isA<CtlFailure>()));
      expect(
        () => parseDirectDownloadKind('movie'),
        throwsA(isA<CtlFailure>()),
      );
    });

    test('buildDirectLinkDiscoveryItem：标题取文件名，payload 已物化', () {
      final DiscoveryResourceItem item = buildDirectLinkDiscoveryItem(
        url: 'https://h.example/files/%E5%B0%8F%E8%AA%AC.epub?sig=abc',
        kind: DiscoveryMediaKind.novel,
      );
      expect(item.sourceId, kDirectLinkDiscoverySourceId);
      expect(item.title, '小説.epub');
      expect(item.payloadKind, DiscoveryPayloadKind.httpFile);
      expect(
        directLinkPayloadOf(item)?.url,
        'https://h.example/files/%E5%B0%8F%E8%AA%AC.epub?sig=abc',
      );
      expect(
        buildDirectLinkDiscoveryItem(
          url: 'https://h.example/',
          kind: DiscoveryMediaKind.game,
          title: ' T ',
        ).title,
        'T',
      );
      expect(
        buildDirectLinkDiscoveryItem(
          url: 'https://h.example/',
          kind: DiscoveryMediaKind.game,
        ).title,
        'h.example',
      );
      expect(
        () => buildDirectLinkDiscoveryItem(
          url: 'ftp://h/x',
          kind: DiscoveryMediaKind.game,
        ),
        throwsFormatException,
      );
    });

    test('发现源条目不被当成直链（resolver 照旧问发现源）', () {
      const DiscoveryResourceItem item = DiscoveryResourceItem(
        sourceId: 'alist',
        title: 'x',
        id: 'x',
        kind: DiscoveryMediaKind.novel,
        payloadKind: DiscoveryPayloadKind.httpFile,
        payload: DiscoveryHttpPayload(url: 'https://h/x'),
      );
      expect(directLinkPayloadOf(item), isNull);
    });

    test('directDownloadTaskToWire 不出完整地址，错误先抹凭据', () {
      final DiscoveryDownloadTask task = DiscoveryDownloadTask.forTesting(
        item: buildDirectLinkDiscoveryItem(
          url: 'https://cdn.example/a.zip?token=s3cr3t',
          kind: DiscoveryMediaKind.game,
        ),
        status: DiscoveryDownloadStatus.failed,
        receivedBytes: 50,
        totalBytes: 200,
      )..error = 'GET https://cdn.example/a.zip?token=s3cr3t 403';
      final Map<String, Object?> wire = directDownloadTaskToWire(task);
      expect(wire['jobId'], 'direct:${task.taskId}');
      expect(wire['host'], 'cdn.example');
      expect(wire['lifecycle'], 'failed');
      expect(wire['stageProgress'], 0.25);
      expect(wire.toString(), isNot(contains('s3cr3t')));
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
