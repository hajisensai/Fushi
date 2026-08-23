import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_video.dart';

void main() {
  List<SettingsItem> allVideoSettings() => <SettingsItem>[
        for (final SettingsSection section in buildVideoDestination().sections)
          ...section.items,
      ];

  SettingsItem item(String id) => allVideoSettings().singleWhere(
        (SettingsItem candidate) => candidate.id == id,
      );

  test('AniDB is fixed as the metadata identity source', () {
    expect(
      allVideoSettings().map((SettingsItem candidate) => candidate.id),
      isNot(contains('video.library.metadata_primary_provider')),
    );
  });

  test('AniDB identity, TMDB key, and locale are reachable from settings', () {
    final Map<String, bool> expectedSecret = <String, bool>{
      'video.library.metadata_anidb_client': false,
      'video.library.metadata_anidb_client_version': false,
      'video.library.tmdb_api_key': true,
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
    final String source =
        File('lib/src/settings/settings_schema_video.dart').readAsStringSync();
    expect(
      RegExp(r'_commitVideoMetadataRuntimePreference\(')
          .allMatches(source)
          .length,
      5,
      reason:
          'the helper definition and all four runtime preferences must use it',
    );
    expect(
      source,
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

  test('obsolete provider settings are no longer exposed', () {
    final Set<String> ids = allVideoSettings()
        .map((SettingsItem candidate) => candidate.id)
        .toSet();
    for (final String obsolete in <String>{
      'video.library.metadata_fanart_api_key',
      'video.library.metadata_bangumi_token',
      'video.library.metadata_douban_endpoint',
      'video.library.metadata_douban_token',
      'video.library.metadata_primary_provider'
    }) {
      expect(ids, isNot(contains(obsolete)));
    }
  });
}
