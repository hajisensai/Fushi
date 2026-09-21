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
    // 图片上限默认取 Shoko 默认值 10/10/10，人物照片默认不落地。
    expect(config.maxCovers, kVideoMetadataDefaultMaxImages);
    expect(config.maxBackdrops, kVideoMetadataDefaultMaxImages);
    expect(config.maxLogos, kVideoMetadataDefaultMaxImages);
    expect(config.downloadStaffImages, isFalse);
    await prefs.setPref(kVideoMetadataMaxCoversPref, 3);
    await prefs.setPref(kVideoMetadataMaxBackdropsPref, 0);
    await prefs.setPref(kVideoMetadataMaxLogosPref, -5);
    await prefs.setPref(kVideoMetadataStaffImagesPref, true);
    final VideoSourceScrapeGlobalConfig limits =
        VideoSourceScrapeGlobalConfig.fromPreferences(prefs,
            resolvedTmdbApiKey: '', uiLocaleTag: 'en-US');
    expect(limits.maxCovers, 3);
    expect(limits.maxBackdrops, 0, reason: '0 = 不限');
    expect(limits.maxLogos, kVideoMetadataDefaultMaxImages,
        reason: '负数不合法回默认');
    expect(limits.downloadStaffImages, isTrue);
    expect(limits.maxImagesPerKind, <VideoMetadataImageKind, int>{
      VideoMetadataImageKind.cover: 3,
      VideoMetadataImageKind.backdrop: 0,
      VideoMetadataImageKind.logo: kVideoMetadataDefaultMaxImages,
    });
  });

  // BUG-2586：设置页状态曾按四个偏好键各自判空，客户端名留空走内置 fushiplayer
  // 的账号「测试登录」成功却显示「未配置」。anidbHashReady 是设置页 / 首页提醒 /
  // 协调器共用的唯一「哈希识别会不会跑」判据。
  group('anidbHashReady (BUG-2586)', () {
    Future<PreferencesRepository> prefsWith(Map<String, Object> values) async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final PreferencesRepository prefs = PreferencesRepository(db);
      addTearDown(prefs.dispose);
      for (final MapEntry<String, Object> entry in values.entries) {
        await prefs.setPref(entry.key, entry.value);
      }
      return prefs;
    }

    VideoSourceScrapeGlobalConfig load(PreferencesRepository prefs) =>
        VideoSourceScrapeGlobalConfig.fromPreferences(prefs,
            resolvedTmdbApiKey: '', uiLocaleTag: 'en-US');

    test('account only, client left blank → bundled client counts as ready',
        () async {
      final PreferencesRepository prefs = await prefsWith(<String, Object>{
        kVideoAniDbHashEnabledPref: true,
        kVideoAniDbUsernamePref: 'tester',
        kVideoAniDbPasswordPref: 'password',
      });
      final VideoSourceScrapeGlobalConfig config = load(prefs);
      expect(config.anidbClientName, 'fushiplayer');
      expect(config.anidbHashReady, isTrue,
          reason: '客户端名 / 版本留空走内置身份，与 testAniDbLogin 同一份配置');
    });

    test('switch off, missing account, or broken custom client → not ready',
        () async {
      final Map<String, Map<String, Object>> cases =
          <String, Map<String, Object>>{
        'switch off': <String, Object>{
          kVideoAniDbUsernamePref: 'tester',
          kVideoAniDbPasswordPref: 'password',
        },
        'no password': <String, Object>{
          kVideoAniDbHashEnabledPref: true,
          kVideoAniDbUsernamePref: 'tester',
        },
        'custom client without version': <String, Object>{
          kVideoAniDbHashEnabledPref: true,
          kVideoAniDbUsernamePref: 'tester',
          kVideoAniDbPasswordPref: 'password',
          kVideoMetadataAniDbClientNamePref: 'customapp',
        },
        'custom client name outside [a-z]{4,16}': <String, Object>{
          kVideoAniDbHashEnabledPref: true,
          kVideoAniDbUsernamePref: 'tester',
          kVideoAniDbPasswordPref: 'password',
          kVideoMetadataAniDbClientNamePref: 'My App',
          kVideoMetadataAniDbClientVersionPref: '2',
        },
      };
      for (final MapEntry<String, Map<String, Object>> entry in cases.entries) {
        final PreferencesRepository prefs = await prefsWith(entry.value);
        expect(load(prefs).anidbHashReady, isFalse, reason: entry.key);
      }
    });

    test('custom client with version → ready', () async {
      final PreferencesRepository prefs = await prefsWith(<String, Object>{
        kVideoAniDbHashEnabledPref: true,
        kVideoAniDbUsernamePref: 'tester',
        kVideoAniDbPasswordPref: 'password',
        kVideoMetadataAniDbClientNamePref: 'customapp',
        kVideoMetadataAniDbClientVersionPref: '2',
      });
      expect(load(prefs).anidbHashReady, isTrue);
    });
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
      int maxCovers = 10,
      int maxBackdrops = 10,
      int maxLogos = 10,
      bool downloadStaffImages = false,
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
          maxCovers: maxCovers,
          maxBackdrops: maxBackdrops,
          maxLogos: maxLogos,
          downloadStaffImages: downloadStaffImages,
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
        'maxCovers': make(maxCovers: 3),
        'maxBackdrops': make(maxBackdrops: 0),
        'maxLogos': make(maxLogos: 1),
        'downloadStaffImages': make(downloadStaffImages: true),
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
