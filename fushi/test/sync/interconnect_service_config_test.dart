import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/sync/interconnect_service_config.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test(
    'host snapshot includes only the explicit cross-device allowlist',
    () async {
      await db.setPref('jimaku_api_key', PrefCodec.encode('jimaku-secret'));
      await db.setPref(
        kVideoMetadataAniDbClientNamePref,
        PrefCodec.encode('fushi-client'),
      );
      await db.setPref(
        kVideoMetadataAniDbClientVersionPref,
        PrefCodec.encode('7'),
      );
      await db.setPref('video_scraper_tmdb_api_key', PrefCodec.encode('tmdb'));
      await db.setPref(
        'video_metadata_fanart_api_key',
        PrefCodec.encode('fanart-secret'),
      );
      await db.setPref(
        'video_metadata_bangumi_token',
        PrefCodec.encode('bangumi-secret'),
      );
      await db.setPref(
        'video_metadata_douban_authorized_endpoint',
        PrefCodec.encode('https://private.example/douban'),
      );
      await db.setPref(
        'video_metadata_douban_authorized_token',
        PrefCodec.encode('douban-secret'),
      );
      await db.setPref(
        'qb_connection_config',
        PrefCodec.encode('{"password":"qb-secret"}'),
      );
      await db.setPref('yomitan_api_key', PrefCodec.encode('local-inbound'));
      await db.setPref(
        'sync_hibiki_client_token',
        PrefCodec.encode('peer-token'),
      );
      await db.setPref('sync_device_id', PrefCodec.encode('device-a'));
      await db.setPref(
        'media_source_secret_7',
        PrefCodec.encode('folder-password'),
      );
      await db.setPref('download_save_root', PrefCodec.encode(r'D:\downloads'));
      await db.setPref(
        kBangumiAccessTokenPref,
        PrefCodec.encode('bangumi-tracking-token'),
      );
      await db.setPref(kBangumiAccountNamePref, PrefCodec.encode('nick'));

      final InterconnectServiceConfigSnapshot snapshot =
          InterconnectServiceConfigSnapshot.fromPreferences(
            await db.getAllPrefs(),
          );

      // 只出白名单里的键；凭据 / 配置清单在 host 上没有行时整个键不下发
      // （缺键 = 不改子设备，见下面的 resource_bt_sites 用例）。
      expect(
        snapshot.preferences.keys,
        everyElement(
          isIn(InterconnectServiceConfigSnapshot.sharedPreferenceKeys),
        ),
      );
      expect(snapshot.preferences, isNot(contains('resource_bt_sites')));
      expect(
        snapshot.preferences['jimaku_api_key'],
        PrefCodec.encode('jimaku-secret'),
      );
      // 现行外部服务身份跟着用户的设备走；退役的视频刮削凭据与本机入站
      // API、配对凭据、设备身份和本地路径都不出境。
      expect(
        snapshot.preferences['video_scraper_tmdb_api_key'],
        PrefCodec.encode('tmdb'),
      );
      expect(
        snapshot.preferences[kVideoMetadataAniDbClientNamePref],
        PrefCodec.encode('fushi-client'),
      );
      expect(
        snapshot.preferences[kVideoMetadataAniDbClientVersionPref],
        PrefCodec.encode('7'),
      );
      expect(
        snapshot.preferences,
        isNot(contains('video_metadata_fanart_api_key')),
      );
      expect(
        snapshot.preferences,
        isNot(contains('video_metadata_bangumi_token')),
      );
      expect(
        snapshot.preferences,
        isNot(contains('video_metadata_douban_authorized_endpoint')),
      );
      expect(
        snapshot.preferences,
        isNot(contains('video_metadata_douban_authorized_token')),
      );
      expect(
        snapshot.preferences[kBangumiAccessTokenPref],
        PrefCodec.encode('bangumi-tracking-token'),
      );
      expect(
        snapshot.preferences[kBangumiAccountNamePref],
        PrefCodec.encode('nick'),
      );
      expect(snapshot.preferences, isNot(contains('yomitan_api_key')));
      expect(snapshot.preferences, isNot(contains('sync_hibiki_client_token')));
      expect(snapshot.preferences, isNot(contains('sync_device_id')));
      expect(snapshot.preferences, isNot(contains('media_source_secret_7')));
      expect(snapshot.preferences, isNot(contains('download_save_root')));
    },
  );

  test('missing host rows of plain settings materialize defaults', () {
    final InterconnectServiceConfigSnapshot snapshot =
        InterconnectServiceConfigSnapshot.fromPreferences(
          const <String, String>{},
        );

    expect(snapshot.preferences['jimaku_enabled'], PrefCodec.encode(true));
    expect(
      snapshot.preferences[kVideoMetadataAniDbClientNamePref],
      PrefCodec.encode(''),
    );
    expect(
      snapshot.preferences[kVideoMetadataAniDbClientVersionPref],
      PrefCodec.encode(''),
    );
    expect(
      snapshot.preferences['manga_online_catalog_base_url'],
      PrefCodec.encode('https://mokuro.moe'),
    );
    expect(
      snapshot.preferences['manga_online_catalog_enabled'],
      PrefCodec.encode(true),
    );
  });

  test('凭据 / 配置清单缺行 = host 从没配过：整个键不下发（含跟随令牌的账号名）', () {
    final InterconnectServiceConfigSnapshot snapshot =
        InterconnectServiceConfigSnapshot.fromPreferences(
          const <String, String>{},
        );

    for (final String key in <String>[
      'resource_bt_sites',
      'video_resource_torznab_config',
      'video_subtitle_opensubtitles_config',
      'qb_connection_config',
      'jimaku_api_key',
      'video_subtitle_subdl_api_key',
      'video_scraper_tmdb_api_key',
      kBangumiAccessTokenPref,
      kBangumiAccountNamePref,
    ]) {
      expect(snapshot.preferences, isNot(contains(key)), reason: key);
    }
  });

  group('resource_bt_sites 导入', () {
    final String childSites = PrefCodec.encode(
      '[{"id":"btchild","url":"https://child.example","format":"nyaa"}]',
    );

    Future<InterconnectServiceConfigSnapshot> viaWire(
      Map<String, String> hostRows,
    ) async => InterconnectServiceConfigSnapshot.fromJson(
      InterconnectServiceConfigSnapshot.fromPreferences(hostRows).toJson(),
    );

    test('host 缺键（旧版本 host / 从没配过）：子设备的 BT 站保持不变', () async {
      await db.setPref('resource_bt_sites', childSites);
      final InterconnectServiceConfigSnapshot snapshot = await viaWire(
        const <String, String>{},
      );
      await snapshot.applyTo(db);
      expect(await db.getPref('resource_bt_sites'), childSites);
    });

    test('旧版本 host 的载荷里根本没有这个键：子设备保持不变', () async {
      await db.setPref('resource_bt_sites', childSites);
      final InterconnectServiceConfigSnapshot snapshot =
          InterconnectServiceConfigSnapshot.fromJson(<String, Object?>{
            'schemaVersion': 1,
            'preferences': <String, Object?>{
              'jimaku_api_key': PrefCodec.encode('k'),
            },
          });
      await snapshot.applyTo(db);
      expect(await db.getPref('resource_bt_sites'), childSites);
    });

    test('host 显式清空（空数组）：子设备随之清空', () async {
      await db.setPref('resource_bt_sites', childSites);
      final String cleared = PrefCodec.encode('[]');
      final InterconnectServiceConfigSnapshot snapshot = await viaWire(
        <String, String>{'resource_bt_sites': cleared},
      );
      await snapshot.applyTo(db);
      expect(await db.getPref('resource_bt_sites'), cleared);
    });

    test('host 有值：覆盖子设备', () async {
      await db.setPref('resource_bt_sites', childSites);
      final String hostSites = PrefCodec.encode(
        '[{"id":"nyaa.si","url":"https://nyaa.si","format":"nyaa"}]',
      );
      final InterconnectServiceConfigSnapshot snapshot = await viaWire(
        <String, String>{'resource_bt_sites': hostSites},
      );
      await snapshot.applyTo(db);
      expect(await db.getPref('resource_bt_sites'), hostSites);
    });
  });

  test('Bangumi 账号名跟令牌成对：令牌有行而名字缺行时名字按空值下发', () {
    final InterconnectServiceConfigSnapshot snapshot =
        InterconnectServiceConfigSnapshot.fromPreferences(<String, String>{
          kBangumiAccessTokenPref: PrefCodec.encode('tok'),
        });
    expect(snapshot.preferences[kBangumiAccountNamePref], PrefCodec.encode(''));
  });

  test('client ignores unknown fields and applies only changed rows', () async {
    await db.setPref('jimaku_api_key', PrefCodec.encode('old'));
    await db.setPref('sync_device_id', PrefCodec.encode('keep-device'));

    final InterconnectServiceConfigSnapshot snapshot =
        InterconnectServiceConfigSnapshot.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'preferences': <String, Object?>{
            'jimaku_api_key': PrefCodec.encode('new'),
            kVideoMetadataAniDbClientNamePref: PrefCodec.encode(
              'synced-client',
            ),
            kVideoMetadataAniDbClientVersionPref: PrefCodec.encode('9'),
            'manga_online_catalog_enabled': PrefCodec.encode(false),
            'sync_device_id': PrefCodec.encode('attacker-device'),
            'future_secret': PrefCodec.encode('attacker-secret'),
          },
        });

    expect(await snapshot.applyTo(db), 4);
    expect(await db.getPref('jimaku_api_key'), PrefCodec.encode('new'));
    expect(
      await db.getPref('manga_online_catalog_enabled'),
      PrefCodec.encode(false),
    );
    expect(
      await db.getPref(kVideoMetadataAniDbClientNamePref),
      PrefCodec.encode('synced-client'),
    );
    expect(
      await db.getPref(kVideoMetadataAniDbClientVersionPref),
      PrefCodec.encode('9'),
    );
    expect(await db.getPref('sync_device_id'), PrefCodec.encode('keep-device'));
    expect(await db.getPref('future_secret'), isNull);
    expect(await snapshot.applyTo(db), 0, reason: 'replay must be idempotent');
  });

  test('换 Bangumi 令牌必须归零本设备对账水位（与设置页写令牌同一条不变式）', () async {
    for (final String key in kBangumiTokenScopedWatermarkPrefs) {
      await db.setPref(key, PrefCodec.encode(99));
    }
    await db.setPref(kBangumiAccessTokenPref, PrefCodec.encode('old-token'));

    final InterconnectServiceConfigSnapshot snapshot =
        InterconnectServiceConfigSnapshot.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'preferences': <String, Object?>{
            kBangumiAccessTokenPref: PrefCodec.encode('new-token'),
            kBangumiAccountNamePref: PrefCodec.encode('someone-else'),
          },
        });

    expect(await snapshot.applyTo(db), 2, reason: '水位归零是令牌那一行的副作用，不额外计数');
    for (final String key in kBangumiTokenScopedWatermarkPrefs) {
      expect(await db.getPref(key), PrefCodec.encode(0), reason: key);
    }
  });

  test('令牌没变时不碰对账水位（重放同一份 host 快照不得倒退进度）', () async {
    await db.setPref(kBangumiAccessTokenPref, PrefCodec.encode('same-token'));
    for (final String key in kBangumiTokenScopedWatermarkPrefs) {
      await db.setPref(key, PrefCodec.encode(99));
    }

    final InterconnectServiceConfigSnapshot snapshot =
        InterconnectServiceConfigSnapshot.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'preferences': <String, Object?>{
            kBangumiAccessTokenPref: PrefCodec.encode('same-token'),
            'jimaku_api_key': PrefCodec.encode('changed'),
          },
        });

    expect(await snapshot.applyTo(db), 1);
    for (final String key in kBangumiTokenScopedWatermarkPrefs) {
      expect(await db.getPref(key), PrefCodec.encode(99), reason: key);
    }
  });

  test('rejects unsupported schema versions', () {
    expect(
      () => InterconnectServiceConfigSnapshot.fromJson(<String, Object?>{
        'schemaVersion': 2,
        'preferences': <String, Object?>{},
      }),
      throwsFormatException,
    );
  });

  test('BUG-1311：明文互联会话不得请求 service-config（403 必然，问了只是伪造失败）', () async {
    // 复刻真实 host 在明文会话上的行为：`fushi_sync_server.dart` 的
    // `_handleInterconnectServiceConfig` 在 `_securityContext == null` 时恒返回
    // `403 HTTPS required for service config`。而 TLS 默认是关的，存量 host 一律
    // 走这条分支——客户端照发请求就会每轮同步收一条 SyncAuthError。
    final List<String> hits = <String>[];
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    unawaited(
      server.forEach((HttpRequest request) async {
        hits.add(request.uri.path);
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write('HTTPS required for service config');
        await request.response.close();
      }),
    );

    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
    ]);
    await repo.setFushiClientToken('peer-token');
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
      (String u, String t) async => true,
    );
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);

    expect(
      await backend.getRemoteServiceConfig(),
      isNull,
      reason: '明文 host 不提供该能力，语义与「旧 host 404」「能力关闭 404」归一',
    );
    // 只断返回值不够——把门控换成「照发请求 + catch 吞掉异常」同样会返回 null。
    // 必须断请求根本没发出去：否则每一轮同步仍会打一次注定 403 的往返，
    // 并把 403 经 webdav_ops.checkStatus 压成 SyncAuthError 挂进 report.errors。
    expect(hits, isEmpty, reason: '明文会话上 service-config 必然 403，这一次请求就不该发出去');
  });

  // ── apikey 同步设定重设计（2026-08-17）：service-config 接收开关 ──────────

  test('service-config 同步开关默认开（既有行为不变）且落库可关', () async {
    final SyncRepository repo = SyncRepository(db);
    expect(
      await repo.isInterconnectServiceConfigSyncEnabled(),
      isTrue,
      reason: '默认 true：TLS 开着的存量互联用户行为零变化',
    );
    await repo.setInterconnectServiceConfigSyncEnabled(false);
    expect(await repo.isInterconnectServiceConfigSyncEnabled(), isFalse);
    await repo.setInterconnectServiceConfigSyncEnabled(true);
    expect(await repo.isInterconnectServiceConfigSyncEnabled(), isTrue);
  });

  test('开关键是设备本地（信任决策不跨设备携带）', () {
    expect(
      SyncRepository.deviceLocalPrefKeys.contains(
        'interconnect_sync_service_config',
      ),
      isTrue,
      reason:
          '「要不要接收 host 凭据」是每台设备自己的信任决策，'
          '随备份漂移会把 A 机的选择强加给 B 机',
    );
  });

  test('编排器在请求 service-config 之前先问开关（关 = 连请求都不发）', () {
    // 源码守卫（orchestrator 的 _syncServiceConfigLive 是私有方法，行为面在
    // run() 全流水线深处）：门控必须出现在 getRemoteServiceConfig 之前——
    // 「拉回来再丢弃」或「拉了不应用」都不满足「关掉就不发请求」的语义。
    // B2 拆分后该方法定义在 aggregate.part.dart（主库里只剩 run() 的调用点，
    // 从调用点往后找门控会假阴）。
    final String src = File(
      'lib/src/sync/sync_orchestrator/aggregate.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int methodStart = src.indexOf('_syncServiceConfigLive(');
    expect(methodStart, greaterThan(0));
    final int gate = src.indexOf(
      'isInterconnectServiceConfigSyncEnabled',
      methodStart,
    );
    final int request = src.indexOf('getRemoteServiceConfig', methodStart);
    expect(gate, greaterThan(0), reason: '门控缺失 = 开关形同虚设');
    expect(request, greaterThan(0));
    expect(gate < request, isTrue, reason: '门控必须先于请求：关掉开关后连 GET 都不该发');
  });
}
