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
}
