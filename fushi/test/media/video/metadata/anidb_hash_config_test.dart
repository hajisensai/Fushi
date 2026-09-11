import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  test(
      'hash runtime snapshot loads the enable switch and preserves password bytes',
      () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    addTearDown(prefs.dispose);
    await prefs.setPref(kVideoAniDbHashEnabledPref, true);
    await prefs.setPref(kVideoAniDbUsernamePref, ' tester ');
    await prefs.setPref(kVideoAniDbPasswordPref, ' password & 日本語 ');
    await prefs.setPref(kVideoMetadataAniDbClientNamePref, ' clientname ');
    await prefs.setPref(kVideoMetadataAniDbClientVersionPref, '3');
    final VideoSourceScrapeGlobalConfig config =
        VideoSourceScrapeGlobalConfig.fromPreferences(prefs,
            resolvedTmdbApiKey: '', uiLocaleTag: 'en-US');
    expect(config.hashEnabled, isTrue);
    expect(config.anidbUdpConfig.isAvailable, isTrue);
    expect(config.anidbUdpConfig.username, 'tester');
    expect(config.anidbUdpConfig.clientName, 'clientname');
    expect(config.anidbUdpConfig.password, ' password & 日本語 ');
  });
}
