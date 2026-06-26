import 'dart:convert';

import 'package:hibiki_anki/hibiki_anki.dart';

import 'package:hibiki/src/models/preferences_repository.dart';

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
    'startup_default_dictionary_tab',
    'app_ui_scale',
    'app_ui_scale_mode',
    'app_locale',
    'last_selected_deck',
    'last_selected_dictionary_format',
    'last_selected_model',
    'update_never_remind',
    'update_auto_install',
    'update_beta_channel',
    // HBK-AUDIT-045: keep ALL update-channel/policy keys app-global so the
    // debug channel isn't asymmetrically profile-scoped vs the others.
    'update_debug_channel',
    // TODO-855: the monotonic prefs-version counter is the cross-process signal
    // the :popup process reads to decide whether to refresh its warm-reuse
    // pref cache. It must stay app-global and monotonic — snapshotting it
    // into a profile (and restoring/wiping it on profile switch) would make
    // the counter non-monotonic and break change detection.
    PreferencesRepository.prefsVersionKey,
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
        'tagIncludeHibiki': s.tagIncludeHibiki.toString(),
        'tagIncludeCategory': s.tagIncludeCategory.toString(),
        'allowDupes': s.allowDupes.toString(),
        'compactGlossaries': s.compactGlossaries.toString(),
        'embedMedia': s.embedMedia.toString(),
      };

  static AnkiSettings mapToAnkiSettings(
    Map<String, String> m,
    AnkiSettings current,
  ) {
    int? parseInt(String? v) => v == null || v.isEmpty ? null : int.tryParse(v);

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
      fieldMappings:
          _parseFieldMappings(m['fieldMappings'], current.fieldMappings),
      tags: m['tags'] ?? '',
      tagIncludeHibiki: m.containsKey('tagIncludeHibiki')
          ? m['tagIncludeHibiki'] == 'true'
          : true,
      tagIncludeCategory: m.containsKey('tagIncludeCategory')
          ? m['tagIncludeCategory'] == 'true'
          : true,
      allowDupes: m['allowDupes'] == 'true',
      compactGlossaries: m['compactGlossaries'] == 'true',
      embedMedia:
          m.containsKey('embedMedia') ? m['embedMedia'] == 'true' : true,
    );
  }

  /// Parses the stored fieldMappings JSON defensively. The value comes from the
  /// profile_settings DB table, which can hold malformed data (manual edit,
  /// aborted snapshot write, cross-version backup import). A single bad row
  /// must not throw and abort the entire profile-apply flow (HBK-AUDIT-043).
  static Map<String, String> _parseFieldMappings(
    String? raw,
    Map<String, String> fallback,
  ) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
            (dynamic k, dynamic v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {
      // Fall through to the fallback below.
    }
    return fallback;
  }
}
