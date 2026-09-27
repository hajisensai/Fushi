// 媒体服务器类型泛化（MediaServerKind）与共用列表键 `sync_jellyfin_servers`（真 DB）。
//
// 锁住：
//  [A] 旧配置（无 `kind` 字段）按 Jellyfin 读取，产出 JSON 仍不带 `kind`（与旧版本
//      逐字相同）；
//  [B] Plex 与 Jellyfin 混存：往返、顺序、按 sourceId upsert（原位）/ remove；
//  [C] 只动 Jellyfin 的旧 API（setJellyfinServers / upsert / remove / 过渡口径）
//      不会把 Plex 项删掉或挪位；
//  [D] 认不出的 `kind` 与脏项逐项丢弃；Plex JSON 刻意不带 Jellyfin 必填键，旧版本
//      按 Jellyfin 解析会把它当脏项丢掉（不会拿 Plex token 去打 Jellyfin 端点）；
//  [E] 线路切换（withActiveRoute）；
//  [F] 两套脱敏（错误文本 / 诊断日志）都认 X-Plex-Token。

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/diagnostics/video_diag_log.dart'
    show redactVideoDiagSecrets;
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_registry.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/media/metadata/credential_redaction.dart';

const String _kListKey = 'sync_jellyfin_servers';

const JellyfinServerConfig _nas = JellyfinServerConfig(
  serverUrl: 'http://nas:8096',
  username: 'alice',
  userId: 'u-nas',
  accessToken: 'tok-nas',
  serverName: 'NAS',
);

const JellyfinServerConfig _emby = JellyfinServerConfig(
  serverUrl: 'https://emby.example.com',
  username: 'bob',
  userId: 'u-emby',
  accessToken: 'tok-emby',
);

const PlexServerConfig _plex = PlexServerConfig(
  machineIdentifier: 'mid-1',
  token: 'plex-token',
  clientIdentifier: 'client-uuid',
  connections: <String>[
    'http://192.168.1.5:32400',
    'https://x.plex.direct:32400',
  ],
  serverName: 'Home PMS',
  accountId: '42',
  accountName: 'carol',
);

void main() {
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
  });

  tearDown(() => db.close());

  Future<String?> rawPref(String key) async {
    final PreferenceRow? row = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> writeRaw(String key, String value) => db
      .into(db.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(key: key, value: value),
      );

  List<String> idsOf(List<MediaServerConfig> servers) => <String>[
    for (final MediaServerConfig s in servers) s.sourceId,
  ];

  group('[A] 旧配置兼容', () {
    test('无 kind 字段的存量 JSON 按 Jellyfin 读取', () async {
      await writeRaw(
        _kListKey,
        jsonEncode(<Object?>[
          <String, Object?>{
            'serverUrl': 'http://nas:8096',
            'username': 'alice',
            'userId': 'u-nas',
            'accessToken': 'tok-nas',
          },
        ]),
      );
      final List<MediaServerConfig> all = await repo.getMediaServers();
      expect(all.single, isA<JellyfinServerConfig>());
      expect(all.single.kind, MediaServerKind.jellyfin);
      expect(all.single.sourceId, 'jellyfin:http://nas:8096|u-nas');
      expect(await repo.getJellyfinServers(), hasLength(1));
    });

    test('MediaServerKind.fromWire：缺字段 = jellyfin，未知 = null', () {
      expect(MediaServerKind.fromWire(null), MediaServerKind.jellyfin);
      expect(MediaServerKind.fromWire('plex'), MediaServerKind.plex);
      expect(MediaServerKind.fromWire('kodi'), isNull);
    });

    test('Jellyfin 产出 JSON 仍不带 kind（与旧版本逐字相同）', () {
      expect(_nas.toJson().containsKey(MediaServerKind.jsonKey), isFalse);
      expect(_plex.toJson()[MediaServerKind.jsonKey], 'plex');
    });
  });

  group('[B] 混存', () {
    test('往返保持顺序与类型；Plex 字段一致', () async {
      await repo.setMediaServers(<MediaServerConfig>[_nas, _plex, _emby]);
      final List<MediaServerConfig> back = await repo.getMediaServers();
      expect(idsOf(back), idsOf(<MediaServerConfig>[_nas, _plex, _emby]));
      final PlexServerConfig plex = back[1] as PlexServerConfig;
      expect(plex.machineIdentifier, 'mid-1');
      expect(plex.token, 'plex-token');
      expect(plex.clientIdentifier, 'client-uuid');
      expect(plex.connections, _plex.connections);
      expect(plex.serverName, 'Home PMS');
      expect(plex.accountName, 'carol');
      expect(plex.sourceId, 'plex:mid-1|42');
      expect(plex.effectiveServerUrl, 'http://192.168.1.5:32400');
      expect(await repo.getJellyfinServers(), hasLength(2));
    });

    test('upsertMediaServer 按 sourceId 原位替换；remove 只删一台', () async {
      await repo.setMediaServers(<MediaServerConfig>[_nas, _plex, _emby]);
      final PlexServerConfig renewed = PlexServerConfig(
        machineIdentifier: 'mid-1',
        token: 'plex-token-2',
        clientIdentifier: 'client-uuid',
        connections: _plex.connections,
        accountId: '42',
      );
      await repo.upsertMediaServer(renewed);
      List<MediaServerConfig> back = await repo.getMediaServers();
      expect(back, hasLength(3));
      expect((back[1] as PlexServerConfig).token, 'plex-token-2');
      await repo.removeMediaServer(_plex.sourceId);
      back = await repo.getMediaServers();
      expect(idsOf(back), idsOf(<MediaServerConfig>[_nas, _emby]));
    });

    test('配置 → 浏览器：Plex 出 PlexVideoClient，身份一致', () {
      const MediaServerConfig c = _plex;
      final Object browser = c.buildBrowser();
      expect(browser, isA<PlexVideoClient>());
      expect((browser as PlexVideoClient).serverId, _plex.sourceId);
      expect(_nas.buildBrowser(), isA<JellyfinVideoClient>());
    });
  });

  group('[C] 旧 Jellyfin API 不误伤 Plex', () {
    test('setJellyfinServers 保留 Plex 原位', () async {
      await repo.setMediaServers(<MediaServerConfig>[_nas, _plex, _emby]);
      await repo.setJellyfinServers(<JellyfinServerConfig>[_emby]);
      expect(
        idsOf(await repo.getMediaServers()),
        idsOf(<MediaServerConfig>[_emby, _plex]),
      );
      await repo.setJellyfinServers(<JellyfinServerConfig>[_emby, _nas]);
      expect(
        idsOf(await repo.getMediaServers()),
        idsOf(<MediaServerConfig>[_emby, _plex, _nas]),
      );
    });

    test('setJellyfinServers([]) 只登出 Jellyfin 家族；只剩 Plex 时键仍在', () async {
      await repo.setMediaServers(<MediaServerConfig>[_nas, _plex]);
      await repo.setJellyfinServers(const <JellyfinServerConfig>[]);
      expect(idsOf(await repo.getMediaServers()), <String>[_plex.sourceId]);
      expect(await rawPref(_kListKey), isNotNull);
      await repo.removeMediaServer(_plex.sourceId);
      expect(await rawPref(_kListKey), isNull, reason: '整表空了才删键');
    });

    test('upsert / remove Jellyfin 与过渡口径不动 Plex', () async {
      await repo.setMediaServers(<MediaServerConfig>[_plex, _nas]);
      await repo.upsertJellyfinServer(_emby);
      await repo.removeJellyfinServer(
        serverUrl: _nas.serverUrl,
        userId: _nas.userId,
      );
      expect(
        idsOf(await repo.getMediaServers()),
        idsOf(<MediaServerConfig>[_plex, _emby]),
      );
      // ignore: deprecated_member_use_from_same_package
      expect((await repo.getJellyfinServer())?.serverUrl, _emby.serverUrl);
    });
  });

  group('[D] 脏项与降级', () {
    test('未知 kind 与缺字段的 Plex 项逐项丢弃', () async {
      await writeRaw(
        _kListKey,
        jsonEncode(<Object?>[
          <String, Object?>{'kind': 'kodi', 'serverUrl': 'http://k'},
          <String, Object?>{'kind': 'plex', 'machineIdentifier': 'm'},
          _plex.toJson(),
          _nas.toJson(),
        ]),
      );
      expect(
        idsOf(await repo.getMediaServers()),
        idsOf(<MediaServerConfig>[_plex, _nas]),
      );
    });

    test('Plex JSON 不含 Jellyfin 必填键：旧版本解析即脏项', () {
      final Map<String, dynamic> json =
          jsonDecode(jsonEncode(_plex.toJson())) as Map<String, dynamic>;
      expect(JellyfinServerConfig.fromJson(json), isNull);
      expect(decodeMediaServerConfig(json), isA<PlexServerConfig>());
    });
  });

  group('[E] 线路', () {
    test('withActiveRoute：切到备用连接；首条 / 未知地址回落首条', () {
      final PlexServerConfig wan = _plex.withActiveRoute(
        'https://x.plex.direct:32400',
      );
      expect(wan.effectiveServerUrl, 'https://x.plex.direct:32400');
      expect(wan.toJson()['activeServerUrl'], 'https://x.plex.direct:32400');
      expect(
        wan.withActiveRoute('http://elsewhere').effectiveServerUrl,
        'http://192.168.1.5:32400',
      );
      expect(
        wan.withActiveRoute(_plex.connections.first).toJson(),
        isNot(contains('activeServerUrl')),
      );
      expect(wan.routeUrls, _plex.connections);
      expect(wan.sourceId, _plex.sourceId, reason: '切线路不换身份');
    });
  });

  group('[F] 脱敏', () {
    const String url =
        'http://pms:32400/library/parts/1/2/file.mkv?X-Plex-Token=SECRET&a=1';

    test('错误文本脱敏认 X-Plex-Token（大小写不敏感）', () {
      expect(
        redactCredentialsInText('ClientException: refused, uri=$url'),
        'ClientException: refused, uri=http://pms:32400/library/parts/1/2/'
        'file.mkv?X-Plex-Token=<redacted>&a=1',
      );
      expect(
        redactCredentialsInText('?x-plex-token=abc'),
        '?x-plex-token=<redacted>',
      );
    });

    test('诊断日志脱敏认 X-Plex-Token 查询参数与请求头', () {
      final String out = redactVideoDiagSecrets(
        '[stream] open $url\nX-Plex-Token: SECRET2',
      );
      expect(out, isNot(contains('SECRET')));
      expect(out, contains('X-Plex-Token=[redacted]'));
    });
  });
}
