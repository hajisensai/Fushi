import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/profile/profile_keys.dart';

void main() {
  group('ProfileKeys.isExcludedPref', () {
    test('excludes known hardcoded keys', () {
      expect(ProfileKeys.isExcludedPref('active_profile_id'), isTrue);
      expect(ProfileKeys.isExcludedPref('first_time_setup'), isTrue);
      expect(ProfileKeys.isExcludedPref('current_home_tab_index'), isTrue);
      expect(ProfileKeys.isExcludedPref('app_locale'), isTrue);
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
    });

    test('excludes keys with current_source/ prefix', () {
      expect(ProfileKeys.isExcludedPref('current_source/reader'), isTrue);
      expect(ProfileKeys.isExcludedPref('current_source/dictionary'), isTrue);
    });

    test('excludes keys with audio_index/ prefix', () {
      expect(ProfileKeys.isExcludedPref('audio_index/book123'), isTrue);
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
}
