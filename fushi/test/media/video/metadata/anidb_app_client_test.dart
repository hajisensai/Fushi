import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/anidb_app_client.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  test('bundled registration supplies only the application identity', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    addTearDown(prefs.dispose);
    final VideoSourceScrapeGlobalConfig config =
        VideoSourceScrapeGlobalConfig.fromPreferences(prefs,
            resolvedTmdbApiKey: '', uiLocaleTag: 'en-US');
    expect(config.anidbClientName, 'fushiplayer');
    expect(config.anidbClientVersion, 1);
    expect(config.anidbUsername, isEmpty);
    expect(config.anidbPassword, isEmpty);
    expect(config.hashEnabled, isFalse);
    expect(config.anidbUdpConfig.isAvailable, isFalse);
    await prefs.setPref(kVideoAniDbUsernamePref, 'myaccount');
    await prefs.setPref(kVideoAniDbPasswordPref, ' my password ');
    final VideoSourceScrapeGlobalConfig personal =
        VideoSourceScrapeGlobalConfig.fromPreferences(prefs,
            resolvedTmdbApiKey: '', uiLocaleTag: 'en-US');
    expect(personal.anidbUdpConfig.isAvailable, isTrue);
    expect(personal.anidbPassword, ' my password ');
    expect(personal.hashEnabled, isFalse);
  });

  test('custom identity overrides the pair and never borrows bundled version',
      () {
    final AniDbAppClientIdentity custom =
        resolveAniDbAppClient(customName: ' customclient ', customVersion: 7);
    expect(custom.name, 'customclient');
    expect(custom.version, 7);
    expect(
        resolveAniDbAppClient(customName: 'customclient', customVersion: null)
            .version,
        isNull);
    final AniDbAppClientIdentity reset =
        resolveAniDbAppClient(customName: '', customVersion: 999);
    expect(reset.name, kBundledAniDbClient.name);
    expect(reset.version, kBundledAniDbClient.version);
  });

  test('an unregistered build cannot invent a client identity', () {
    final AniDbAppClientIdentity pending = resolveAniDbAppClient(
        customName: '',
        customVersion: 1,
        bundled: const AniDbAppClientIdentity.unregistered());
    expect(pending.name, isEmpty);
    expect(pending.version, isNull);
  });
}
