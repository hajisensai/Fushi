import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/profile/profile_keys.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki/src/sync/pref_redaction_policy.dart';

void main() {
  group('ProfileKeys.isExcludedPref', () {
    test('excludes known hardcoded keys', () {
      expect(ProfileKeys.isExcludedPref('active_profile_id'), isTrue);
      expect(ProfileKeys.isExcludedPref('first_time_setup'), isTrue);
      expect(ProfileKeys.isExcludedPref('current_home_tab_index'), isTrue);
      expect(ProfileKeys.isExcludedPref('app_locale'), isTrue);
      expect(ProfileKeys.isExcludedPref('airing_calendar_cache'), isTrue);
      expect(ProfileKeys.isExcludedPref('last_selected_deck'), isTrue);
      expect(ProfileKeys.isExcludedPref('last_selected_dictionary_format'),
          isTrue);
      expect(ProfileKeys.isExcludedPref('last_selected_model'), isTrue);
      expect(ProfileKeys.isExcludedPref('update_never_remind'), isTrue);
      expect(ProfileKeys.isExcludedPref('update_auto_install'), isTrue);
      expect(ProfileKeys.isExcludedPref('update_beta_channel'), isTrue);
      expect(
          ProfileKeys.isExcludedPref('startup_default_dictionary_tab'), isTrue);
      expect(ProfileKeys.isExcludedPref('app_ui_scale'), isTrue);
      expect(ProfileKeys.isExcludedPref('app_ui_scale_mode'), isTrue);
      expect(ProfileKeys.isExcludedPref('download_network_proxy_mode'), isTrue);
      expect(ProfileKeys.isExcludedPref('download_custom_proxy'), isTrue);
      // TODO-1961: download folder + legacy-folder history are device-local.
      expect(ProfileKeys.isExcludedPref('download_save_root'), isTrue);
      expect(ProfileKeys.isExcludedPref('download_save_root_history'), isTrue);
      expect(
        ProfileKeys.isExcludedPref(
          ProfileKeys.obsoleteGalgameUpscalingModePrefKey,
        ),
        isTrue,
        reason: 'v63 删除的旧全局超分键不得再进入 Profile 快照',
      );
    });

    test('excludes keys with current_source/ prefix', () {
      expect(ProfileKeys.isExcludedPref('current_source/reader'), isTrue);
      expect(ProfileKeys.isExcludedPref('current_source/dictionary'), isTrue);
    });

    test('excludes keys ending with /last_picked_file', () {
      expect(ProfileKeys.isExcludedPref('epub/last_picked_file'), isTrue);
      expect(ProfileKeys.isExcludedPref('srt/last_picked_file'), isTrue);
    });

    test('does not exclude regular preference keys', () {
      expect(ProfileKeys.isExcludedPref('font_size'), isFalse);
      expect(ProfileKeys.isExcludedPref('theme_color'), isFalse);
      expect(ProfileKeys.isExcludedPref('reader_vertical'), isFalse);
    });

    test(
        'BUG-1019: per-book audiobook playback state is progress, '
        'never profile-snapshotted', () {
      expect(ProfileKeys.isExcludedPref('audiobook_pos_bookA'), isTrue);
      expect(ProfileKeys.isExcludedPref('audiobook_pos_at_bookA'), isTrue);
      expect(ProfileKeys.isExcludedPref('audiobook_speed_bookA'), isTrue);
      expect(ProfileKeys.isExcludedPref('audiobook_follow_bookA'), isTrue);
      expect(ProfileKeys.isExcludedPref('audiobook_delay_bookA'), isTrue);
      expect(ProfileKeys.isExcludedPref('audiobook_volume_bookA'), isTrue);
      expect(ProfileKeys.isExcludedPref('audiobook_image_pause_bookA'), isTrue);
      expect(
          ProfileKeys.isExcludedPref('audiobook_health_overlay_bookA'), isTrue);
    });

    test('BUG-1018 (A4): override_title prefs are content, never snapshotted',
        () {
      // Persisted form: src:<sourceId>:override_title://<sourceId>/<uniqueKey>
      expect(
        ProfileKeys.isExcludedPref('src:reader_ttu:override_title://reader_ttu/'
            'reader_ttu/hoshi://book/我的书'),
        isTrue,
      );
      expect(
        ProfileKeys.isExcludedPref('src:reader_ttu:override_title://reader_ttu/'
            'reader_ttu/hoshi://srtbook/srtbook_123'),
        isTrue,
      );
    });

    test('reading goals are per-Profile (not excluded, TODO-1046)', () {
      // 0=off, but the goal targets themselves are per-Profile prefs: they must
      // NOT be in the exclusion set so each profile keeps its own daily/weekly
      // target.
      expect(ProfileKeys.isExcludedPref('reading_goal_daily_chars'), isFalse);
      expect(ProfileKeys.isExcludedPref('reading_goal_weekly_chars'), isFalse);
    });
  });

  group('ProfileKeys.ankiSettingsToMap', () {
    test('serializes all fields to string map', () {
      final settings = AnkiSettings(
        selectedDeckId: 1,
        selectedDeckName: 'Japanese',
        selectedNoteTypeId: 2,
        selectedNoteTypeName: 'Basic',
        fieldMappings: {'Front': 'term', 'Back': 'meaning'},
        tags: 'japanese vocab',
        allowDupes: true,
        compactGlossaries: false,
        embedMedia: true,
      );

      final map = ProfileKeys.ankiSettingsToMap(settings);

      expect(map['selectedDeckId'], '1');
      expect(map['selectedDeckName'], 'Japanese');
      expect(map['selectedNoteTypeId'], '2');
      expect(map['selectedNoteTypeName'], 'Basic');
      expect(map['tags'], 'japanese vocab');
      expect(map['allowDupes'], 'true');
      expect(map['compactGlossaries'], 'false');
      expect(map['embedMedia'], 'true');
      expect(jsonDecode(map['fieldMappings']!),
          {'Front': 'term', 'Back': 'meaning'});
    });

    test('null ids serialize as empty strings', () {
      const settings = AnkiSettings();

      final map = ProfileKeys.ankiSettingsToMap(settings);

      expect(map['selectedDeckId'], '');
      expect(map['selectedDeckName'], '');
    });
  });

  group('ProfileKeys.mapToAnkiSettings', () {
    test('deserializes a complete map back to AnkiSettings', () {
      final map = {
        'selectedDeckId': '42',
        'selectedDeckName': 'Deck',
        'selectedNoteTypeId': '7',
        'selectedNoteTypeName': 'Note',
        'fieldMappings': '{"Front":"term"}',
        'tags': 'tag1 tag2',
        'allowDupes': 'true',
        'compactGlossaries': 'true',
        'embedMedia': 'false',
      };
      const current = AnkiSettings(
        availableDecks: [AnkiDeck(id: 1, name: 'D')],
      );

      final result = ProfileKeys.mapToAnkiSettings(map, current);

      expect(result.selectedDeckId, 42);
      expect(result.selectedDeckName, 'Deck');
      expect(result.selectedNoteTypeId, 7);
      expect(result.selectedNoteTypeName, 'Note');
      expect(result.fieldMappings, {'Front': 'term'});
      expect(result.tags, 'tag1 tag2');
      expect(result.allowDupes, isTrue);
      expect(result.compactGlossaries, isTrue);
      expect(result.embedMedia, isFalse);
      expect(result.availableDecks, hasLength(1));
    });

    test('empty strings yield null for optional fields', () {
      final map = {
        'selectedDeckId': '',
        'selectedDeckName': '',
        'selectedNoteTypeId': '',
        'selectedNoteTypeName': '',
        'fieldMappings': '{}',
        'tags': '',
        'allowDupes': 'false',
        'compactGlossaries': 'false',
      };
      const current = AnkiSettings();

      final result = ProfileKeys.mapToAnkiSettings(map, current);

      expect(result.selectedDeckId, isNull);
      expect(result.selectedDeckName, isNull);
      expect(result.selectedNoteTypeId, isNull);
      expect(result.selectedNoteTypeName, isNull);
    });

    test('missing embedMedia key defaults to true', () {
      final map = <String, String>{
        'selectedDeckId': '',
        'selectedDeckName': '',
        'selectedNoteTypeId': '',
        'selectedNoteTypeName': '',
        'fieldMappings': '{}',
        'tags': '',
        'allowDupes': 'false',
        'compactGlossaries': 'false',
      };
      const current = AnkiSettings();

      final result = ProfileKeys.mapToAnkiSettings(map, current);

      expect(result.embedMedia, isTrue);
    });
  });

  group('ProfileKeys.isExcludedPref — credentials never enter a snapshot', () {
    // 快照的写（snapshotCurrentSettings）、读（applyProfile 的 restore map）和
    // 剪枝（applyProfile 的 prune loop）三处都走这个谓词，所以在这里排除凭据
    // 一次生效三处：不再产生新的凭据快照行、存量凭据行不会被回写、切 Profile
    // 也不会把本机凭据剪掉。
    test('excludes device-local + credential prefs', () {
      const List<String> credentials = <String>[
        'sync_webdav_password',
        'sync_sftp_private_key',
        'sync_desktop_credentials',
        'sync_hibiki_client_token',
        'media_source_secret_1',
        'qb_connection_config',
        'yomitan_api_key',
        'jimaku_api_key',
        'manga_cloud_ocr_api_key',
        'video_scraper_tmdb_api_key',
      ];
      for (final String key in credentials) {
        expect(ProfileKeys.isExcludedPref(key), isTrue,
            reason: '$key 会随 Profile 快照进备份 / 分享 JSON');
      }
    });

    test('delegates to the shared policy rather than re-implementing it', () {
      // 防漂移：任何只改 PrefRedactionPolicy 而漏改这里的做法都会被这条抓住。
      for (final String key in PrefRedactionPolicy.sensitiveKeys) {
        expect(ProfileKeys.isExcludedPref(key), isTrue);
      }
      for (final String substring in PrefRedactionPolicy.credentialSubstrings) {
        expect(ProfileKeys.isExcludedPref('any_subsystem_$substring'), isTrue);
      }
    });

    test('still lets genuine per-profile preferences through', () {
      for (final String key in <String>[
        'reader_font_size',
        'reader_theme',
        'sync_auto_enabled',
        'favorite_sentences',
      ]) {
        expect(ProfileKeys.isExcludedPref(key), isFalse,
            reason: '$key 是真正的 per-profile 偏好，排除会让切 Profile 失效');
      }
    });

    test('backup_service pins the same profile_settings category constant', () {
      // backup_service 为避免回边而复制了 'pref' 字面量；两者漂开会让导出侧
      // 的 profile_settings 剔除静默失配（删不到任何行）。
      expect(BackupService.profilePrefCategory, ProfileKeys.categoryPref);
    });
  });
}
