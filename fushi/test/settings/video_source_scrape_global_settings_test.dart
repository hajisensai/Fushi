import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/settings/settings_schema_video.dart';

void main() {
  // AniDB 身份 / TMDB key 是第三方凭据，住「在线服务」分区；刮削语言是刮削行为
  // 偏好，留在视频·媒体库。两处合起来才是完整的刮削运行期偏好面。
  List<SettingsItem> allScrapeSettings() => <SettingsItem>[
        for (final SettingsSection section in buildVideoDestination().sections)
          ...section.items,
        for (final SettingsSection section
            in buildServicesDestination().sections)
          ...section.items,
      ];

  SettingsItem item(String id) => allScrapeSettings().singleWhere(
        (SettingsItem candidate) => candidate.id == id,
      );

  test('primary metadata source is user-selectable between MAL and TMDB', () {
    // 2026-09-08 起主源可选（BUG-2268）：这一项从「必须不存在」翻成「必须存在
    // 且只有 MAL / TMDB 两个选项」——AniDB 等历史 provider 仍不可选。
    final SettingsSegmentedItem<String> picker =
        item('video.library.metadata_primary_provider')
            as SettingsSegmentedItem<String>;
    expect(
      picker.options.map((SettingsSegmentOption<String> option) => option.value),
      <String>['mal', 'tmdb'],
    );
  });

  test('AniDB identity, TMDB key, and locale are reachable from settings', () {
    final Map<String, bool> expectedSecret = <String, bool>{
      'services.metadata.anidb_client': false,
      'services.metadata.anidb_client_version': false,
      'services.metadata.anidb_username': false,
      'services.metadata.anidb_password': true,
      'services.metadata.tmdb_api_key': true,
      'video.library.metadata_locale': false,
    };

    for (final MapEntry<String, bool> entry in expectedSecret.entries) {
      final SettingsTextItem textItem = item(entry.key) as SettingsTextItem;
      expect(
        textItem.secret,
        entry.value,
        reason: '${entry.key} secret rendering mismatch',
      );
    }
  });

  test('metadata runtime preferences rebuild the download scraper snapshot',
      () {
    final String videoSource =
        File('lib/src/settings/settings_schema_video.dart').readAsStringSync();
    final String servicesSource =
        File('lib/src/settings/settings_schema_services.dart')
            .readAsStringSync();
    final String actionsSource =
        File('lib/src/media/video/video_settings_actions.dart')
            .readAsStringSync();
    final RegExp call = RegExp(r'commitVideoMetadataRuntimePreference\(');
    expect(
      call.allMatches(videoSource).length,
      3,
      reason: '刮削语言、主资料源、识别词三项都必须走同一个写穿 helper '
          '（写完要重建下载流水线的刮削快照，否则下一批刮削还用旧值）',
    );
    expect(
      call.allMatches(servicesSource).length,
      5,
      reason:
          'AniDB client/version/account + TMDB key must use the shared helper',
    );
    expect(
      call.allMatches(actionsSource).length,
      1,
      reason: 'the helper is defined once, in video_settings_actions.dart',
    );
    expect(
      actionsSource,
      contains('await settingsContext.appModel.'
          'reloadVideoDownloadPipelineRuntime();'),
    );
  });

  test('invalid AniDB versions disable the HTTP API safely', () {
    expect(parseAniDbClientVersion('1'), 1);
    expect(parseAniDbClientVersion(' 42 '), 42);
    expect(parseAniDbClientVersion('0'), isNull);
    expect(parseAniDbClientVersion('-1'), isNull);
    expect(parseAniDbClientVersion('not-a-number'), isNull);
    expect(parseAniDbClientVersion(null), isNull);
  });

  test('hash identification is opt-in and requires all registration fields',
      () {
    expect(item('services.metadata.anidb_hash_enabled'),
        isA<SettingsSwitchItem>());
    const VideoSourceScrapeGlobalConfig empty = VideoSourceScrapeGlobalConfig();
    expect(empty.hashEnabled, isFalse);
    expect(empty.anidbUdpConfig.isAvailable, isFalse);
    const VideoSourceScrapeGlobalConfig configured =
        VideoSourceScrapeGlobalConfig(
      hashEnabled: true,
      anidbUsername: 'tester',
      anidbPassword: ' spaced password ',
      anidbClientName: 'fushitest',
      anidbClientVersion: 1,
    );
    expect(configured.anidbUdpConfig.isAvailable, isTrue);
    expect(configured.anidbUdpConfig.password, ' spaced password ');
  });

  test('obsolete provider settings are no longer exposed', () {
    final Set<String> ids = allScrapeSettings()
        .map((SettingsItem candidate) => candidate.id)
        .toSet();
    for (final String obsolete in <String>{
      'video.library.metadata_fanart_api_key',
      'video.library.metadata_bangumi_token',
      'video.library.metadata_douban_endpoint',
      'video.library.metadata_douban_token',
    }) {
      expect(ids, isNot(contains(obsolete)));
    }
  });
}
