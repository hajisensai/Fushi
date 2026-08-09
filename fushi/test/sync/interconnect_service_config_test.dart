import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_service_config.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('host snapshot includes only the explicit cross-device allowlist',
      () async {
    await db.setPref('jimaku_api_key', PrefCodec.encode('jimaku-secret'));
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
        'sync_hibiki_client_token', PrefCodec.encode('peer-token'));
    await db.setPref('sync_device_id', PrefCodec.encode('device-a'));
    await db.setPref(
      'media_source_secret_7',
      PrefCodec.encode('folder-password'),
    );
    await db.setPref('download_save_root', PrefCodec.encode(r'D:\downloads'));

    final InterconnectServiceConfigSnapshot snapshot =
        InterconnectServiceConfigSnapshot.fromPreferences(
      await db.getAllPrefs(),
    );

    expect(snapshot.preferences.keys,
        InterconnectServiceConfigSnapshot.sharedPreferenceKeys);
    expect(snapshot.preferences['jimaku_api_key'],
        PrefCodec.encode('jimaku-secret'));
    expect(snapshot.preferences, isNot(contains('video_scraper_tmdb_api_key')));
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
    expect(snapshot.preferences, isNot(contains('yomitan_api_key')));
    expect(snapshot.preferences, isNot(contains('sync_hibiki_client_token')));
    expect(snapshot.preferences, isNot(contains('sync_device_id')));
    expect(snapshot.preferences, isNot(contains('media_source_secret_7')));
    expect(snapshot.preferences, isNot(contains('download_save_root')));
  });

  test('missing host rows materialize defaults so clearing propagates', () {
    final InterconnectServiceConfigSnapshot snapshot =
        InterconnectServiceConfigSnapshot.fromPreferences(
      const <String, String>{},
    );

    expect(snapshot.preferences['jimaku_api_key'], PrefCodec.encode(''));
    expect(
      snapshot.preferences['manga_online_catalog_base_url'],
      PrefCodec.encode('https://mokuro.moe'),
    );
    expect(
      snapshot.preferences['manga_online_catalog_enabled'],
      PrefCodec.encode(true),
    );
  });

  test('client ignores unknown fields and applies only changed rows', () async {
    await db.setPref('jimaku_api_key', PrefCodec.encode('old'));
    await db.setPref('sync_device_id', PrefCodec.encode('keep-device'));

    final InterconnectServiceConfigSnapshot snapshot =
        InterconnectServiceConfigSnapshot.fromJson(<String, Object?>{
      'schemaVersion': 1,
      'preferences': <String, Object?>{
        'jimaku_api_key': PrefCodec.encode('new'),
        'manga_online_catalog_enabled': PrefCodec.encode(false),
        'sync_device_id': PrefCodec.encode('attacker-device'),
        'future_secret': PrefCodec.encode('attacker-secret'),
      },
    });

    expect(await snapshot.applyTo(db), 2);
    expect(
      await db.getPref('jimaku_api_key'),
      PrefCodec.encode('new'),
    );
    expect(
      await db.getPref('manga_online_catalog_enabled'),
      PrefCodec.encode(false),
    );
    expect(
      await db.getPref('sync_device_id'),
      PrefCodec.encode('keep-device'),
    );
    expect(await db.getPref('future_secret'), isNull);
    expect(await snapshot.applyTo(db), 0, reason: 'replay must be idempotent');
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
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    unawaited(server.forEach((HttpRequest request) async {
      hits.add(request.uri.path);
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('HTTPS required for service config');
      await request.response.close();
    }));

    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
    ]);
    await repo.setFushiClientToken('peer-token');
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String u, String t) async => true);
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
    expect(
      hits,
      isEmpty,
      reason: '明文会话上 service-config 必然 403，这一次请求就不该发出去',
    );
  });
}
