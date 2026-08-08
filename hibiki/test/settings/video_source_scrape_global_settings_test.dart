import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_video.dart';

void main() {
  List<SettingsItem> allVideoSettings() => <SettingsItem>[
        for (final SettingsSection section in buildVideoDestination().sections)
          ...section.items,
      ];

  SettingsItem item(String id) => allVideoSettings().singleWhere(
        (SettingsItem candidate) => candidate.id == id,
      );

  test('video metadata global provider exposes exactly four main sources', () {
    final SettingsSegmentedItem<String> provider =
        item('video.library.metadata_primary_provider')
            as SettingsSegmentedItem<String>;

    expect(provider.dropdown, isTrue);
    expect(
      provider.options
          .map((SettingsSegmentOption<String> option) => option.value),
      <String>['tmdb', 'bangumi', 'anilist', 'douban'],
    );
    expect(
      provider.options
          .map((SettingsSegmentOption<String> option) => option.value),
      isNot(contains('fanart')),
      reason: 'Fanart only supplements images and cannot be the main source',
    );
  });

  test('provider credentials and locale are reachable from video settings', () {
    final Map<String, bool> expectedSecret = <String, bool>{
      'video.library.tmdb_api_key': true,
      'video.library.metadata_fanart_api_key': true,
      'video.library.metadata_bangumi_token': true,
      'video.library.metadata_douban_endpoint': false,
      'video.library.metadata_douban_token': true,
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

  test('Douban settings state the authorized endpoint and token gate', () {
    final SettingsSegmentedItem<String> provider =
        item('video.library.metadata_primary_provider')
            as SettingsSegmentedItem<String>;
    final SettingsTextItem endpoint =
        item('video.library.metadata_douban_endpoint') as SettingsTextItem;
    final SettingsTextItem token =
        item('video.library.metadata_douban_token') as SettingsTextItem;

    expect(provider.subtitle, isNotEmpty);
    expect(endpoint.subtitle, contains('unavailable unless both'));
    expect(token.subtitle, contains('unavailable unless both'));
  });
}
