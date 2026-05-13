import 'dart:convert';

import 'package:hibiki/src/anki/anki_models.dart';

class ProfileKeys {
  ProfileKeys._();

  static const String categoryAnki = 'anki';
  static const String categoryPref = 'pref';

  // Legacy categories (pre-v2 snapshots stored dictionary/reader separately)
  static const String categoryDictionary = 'dictionary';
  static const String categoryReader = 'reader';

  static const Set<String> _excludedPrefKeys = {
    'active_profile_id',
    'first_time_setup',
    'current_home_tab_index',
    'app_locale',
    'last_selected_deck',
    'last_selected_dictionary_format',
    'last_selected_model',
    'update_never_remind',
    'update_auto_install',
    'update_beta_channel',
  };

  static const List<String> _excludedPrefPrefixes = [
    'current_source/',
    'audio_index/',
  ];

  static bool isExcludedPref(String key) {
    if (_excludedPrefKeys.contains(key)) return true;
    for (final prefix in _excludedPrefPrefixes) {
      if (key.startsWith(prefix)) return true;
    }
    if (key.endsWith('/last_picked_file')) return true;
    return false;
  }

  static Map<String, String> ankiSettingsToMap(AnkiSettings s) => {
        'selectedDeckId': s.selectedDeckId?.toString() ?? '',
        'selectedDeckName': s.selectedDeckName ?? '',
        'selectedNoteTypeId': s.selectedNoteTypeId?.toString() ?? '',
        'selectedNoteTypeName': s.selectedNoteTypeName ?? '',
        'fieldMappings': jsonEncode(s.fieldMappings),
        'tags': s.tags,
        'allowDupes': s.allowDupes.toString(),
        'compactGlossaries': s.compactGlossaries.toString(),
        'embedMedia': s.embedMedia.toString(),
      };

  static AnkiSettings mapToAnkiSettings(
    Map<String, String> m,
    AnkiSettings current,
  ) {
    int? parseInt(String? v) =>
        v == null || v.isEmpty ? null : int.tryParse(v);

    return AnkiSettings(
      selectedDeckId: parseInt(m['selectedDeckId']),
      selectedDeckName: m['selectedDeckName']?.isNotEmpty == true
          ? m['selectedDeckName']
          : null,
      selectedNoteTypeId: parseInt(m['selectedNoteTypeId']),
      selectedNoteTypeName: m['selectedNoteTypeName']?.isNotEmpty == true
          ? m['selectedNoteTypeName']
          : null,
      availableDecks: current.availableDecks,
      availableNoteTypes: current.availableNoteTypes,
      fieldMappings: m.containsKey('fieldMappings')
          ? Map<String, String>.from(jsonDecode(m['fieldMappings']!) as Map)
          : const {},
      tags: m['tags'] ?? '',
      allowDupes: m['allowDupes'] == 'true',
      compactGlossaries: m['compactGlossaries'] == 'true',
      embedMedia: m.containsKey('embedMedia')
          ? m['embedMedia'] == 'true'
          : true,
    );
  }
}
