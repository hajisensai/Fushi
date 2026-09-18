import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/scraper/scrape_identifier_words.dart';

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

  // BUG-2581：手动刮削装配点曾手抄指纹并漏掉哈希开关 / 账号，用户填好 AniDB
  // 账号后仍复用旧协调器（里面的 AnidbHashIdentityService 还是「未配置」快照）。
  // 每个会进协调器构造快照的字段都必须改变指纹。
  group('runtimeFingerprint (BUG-2581)', () {
    VideoSourceScrapeGlobalConfig make({
      String tmdbApiKey = 'k',
      String anidbClientName = 'fushiplayer',
      int? anidbClientVersion = 1,
      bool hashEnabled = false,
      String anidbUsername = '',
      String anidbPassword = '',
      String locale = 'zh-CN',
      VideoMetadataProviderKind primaryProvider = VideoMetadataProviderKind.mal,
      String identifierWords = '',
    }) =>
        VideoSourceScrapeGlobalConfig(
          tmdbApiKey: tmdbApiKey,
          anidbClientName: anidbClientName,
          anidbClientVersion: anidbClientVersion,
          hashEnabled: hashEnabled,
          anidbUsername: anidbUsername,
          anidbPassword: anidbPassword,
          locale: locale,
          primaryProvider: primaryProvider,
          identifierWords: ScrapeIdentifierWords.parse(
            identifierWords,
          ).identifierWords,
        );

    test('every coordinator-baked field changes the fingerprint', () {
      final String original = make().runtimeFingerprint;
      final Map<String, VideoSourceScrapeGlobalConfig> variants =
          <String, VideoSourceScrapeGlobalConfig>{
        'hashEnabled': make(hashEnabled: true),
        'anidbUsername': make(anidbUsername: 'shishamo'),
        'anidbPassword': make(anidbPassword: 'secret'),
        'anidbClientName': make(anidbClientName: 'custom'),
        'anidbClientVersion': make(anidbClientVersion: 2),
        'tmdbApiKey': make(tmdbApiKey: 'other'),
        'locale': make(locale: 'ja'),
        'primaryProvider': make(
          primaryProvider: VideoMetadataProviderKind.tmdb,
        ),
        'identifierWords': make(identifierWords: 'Kusuriya => Frieren'),
      };
      for (final MapEntry<String, VideoSourceScrapeGlobalConfig> entry
          in variants.entries) {
        expect(
          entry.value.runtimeFingerprint,
          isNot(original),
          reason: '${entry.key} must participate in runtimeFingerprint',
        );
      }
      expect(make().runtimeFingerprint, original);
    });

    test('home page assembly points use the shared fingerprint', () {
      final String source = File(
        'lib/src/pages/implementations/home_page.dart',
      ).readAsStringSync();
      expect(
        source,
        isNot(contains('fingerprint = <Object>[')),
        reason: '别再手抄指纹字段，统一走 config.runtimeFingerprint',
      );
      expect(
        RegExp(r'config\.runtimeFingerprint').allMatches(source).length,
        greaterThanOrEqualTo(2),
        reason: '发现页控制器与手动刮削控制器都必须用 runtimeFingerprint',
      );
    });
  });
}
