import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/interconnect_service_config.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late HibikiDatabase db;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('host snapshot includes only the explicit cross-device allowlist',
      () async {
    await db.setPref('jimaku_api_key', PrefCodec.encode('jimaku-secret'));
    await db.setPref('video_scraper_tmdb_api_key', PrefCodec.encode('tmdb'));
    await db.setPref(
      'qb_connection_config',
      PrefCodec.encode('{"password":"qb-secret"}'),
    );
    await db.setPref(
      'manga_online_catalog_base_url',
      PrefCodec.encode('https://catalog.example'),
    );
    await db.setPref(
      'manga_online_catalog_enabled',
      PrefCodec.encode(false),
    );
    await db.setPref('yomitan_api_key', PrefCodec.encode('local-inbound'));
    await db.setPref(
        'sync_hibiki_client_token', PrefCodec.encode('peer-token'));
    await db.setPref('sync_server_password', PrefCodec.encode('host-password'));
    await db.setPref('sync_device_id', PrefCodec.encode('device-a'));
    await db.setPref('bangumi_access_token', PrefCodec.encode('bangumi-token'));
    await db.setPref('anki_connect_api_key', PrefCodec.encode('anki-token'));
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
    expect(
      snapshot.preferences['video_scraper_tmdb_api_key'],
      PrefCodec.encode('tmdb'),
    );
    expect(
      snapshot.preferences['qb_connection_config'],
      PrefCodec.encode('{"password":"qb-secret"}'),
    );
    expect(
      snapshot.preferences['manga_online_catalog_base_url'],
      PrefCodec.encode('https://catalog.example'),
    );
    expect(
      snapshot.preferences['manga_online_catalog_enabled'],
      PrefCodec.encode(false),
    );
    const Set<String> excluded = <String>{
      'yomitan_api_key',
      'sync_hibiki_client_token',
      'sync_server_password',
      'sync_device_id',
      'bangumi_access_token',
      'anki_connect_api_key',
      'media_source_secret_7',
      'download_save_root',
    };
    expect(snapshot.preferences.keys.toSet().intersection(excluded), isEmpty);
    final String wirePayload = snapshot.toJson().toString();
    for (final String excludedValue in <String>[
      'local-inbound',
      'peer-token',
      'host-password',
      'device-a',
      'bangumi-token',
      'anki-token',
      'folder-password',
      r'D:\downloads',
    ]) {
      expect(wirePayload, isNot(contains(excludedValue)));
    }
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
        'video_scraper_tmdb_api_key': PrefCodec.encode('tmdb-new'),
        'qb_connection_config': PrefCodec.encode('{"host":"qb-new"}'),
        'manga_online_catalog_base_url':
            PrefCodec.encode('https://catalog-new.example'),
        'manga_online_catalog_enabled': PrefCodec.encode(false),
        'sync_device_id': PrefCodec.encode('attacker-device'),
        'future_secret': PrefCodec.encode('attacker-secret'),
        'future_non_string': <String, Object?>{'secret': true},
      },
    });

    expect(await snapshot.applyTo(db), 5);
    expect(
      await db.getPref('jimaku_api_key'),
      PrefCodec.encode('new'),
    );
    expect(
      await db.getPref('video_scraper_tmdb_api_key'),
      PrefCodec.encode('tmdb-new'),
    );
    expect(
      await db.getPref('qb_connection_config'),
      PrefCodec.encode('{"host":"qb-new"}'),
    );
    expect(
      await db.getPref('manga_online_catalog_base_url'),
      PrefCodec.encode('https://catalog-new.example'),
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
    expect(await db.getPref('future_non_string'), isNull);
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
}
