import 'dart:convert';

import 'package:hibiki/src/anki/anki_models.dart';

class ProfileKeys {
  ProfileKeys._();

  static const String categoryAnki = 'anki';
  static const String categoryDictionary = 'dictionary';
  static const String categoryReader = 'reader';

  static const List<String> ankiKeys = [
    'selectedDeckId',
    'selectedDeckName',
    'selectedNoteTypeId',
    'selectedNoteTypeName',
    'fieldMappings',
    'tags',
    'allowDupes',
    'compactGlossaries',
    'embedMedia',
  ];

  static const List<String> dictionaryKeys = [
    'auto_search',
    'auto_search_debounce_delay',
    'dictionary_entry_font_size',
    'maximum_terms',
    'collapse_dictionaries',
    'deduplicate_pitch_accents',
    'harmonic_frequency',
    'auto_add_book_name_to_tags',
    'popup_max_width',
    'custom_dict_css',
    'global_dict_css',
    'local_audio_enabled',
    'local_audio_db_path',
    'local_audio_db_display_name',
  ];

  static const List<String> readerKeys = [
    'ttu_font_size',
    'ttu_line_height',
    'ttu_text_indentation',
    'ttu_writing_mode',
    'ttu_view_mode',
    'ttu_page_columns',
    'ttu_margin_top',
    'ttu_margin_bottom',
    'ttu_margin_left',
    'ttu_margin_right',
    'ttu_vert_kerning',
    'ttu_font_vpal',
    'ttu_vert_text_orient',
    'ttu_text_justify',
    'ttu_reader_styles',
    'ttu_furigana_mode',
  ];

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

    return current.copyWith(
      selectedDeckId: parseInt(m['selectedDeckId']) ?? current.selectedDeckId,
      selectedDeckName:
          m['selectedDeckName']?.isNotEmpty == true
              ? m['selectedDeckName']
              : current.selectedDeckName,
      selectedNoteTypeId:
          parseInt(m['selectedNoteTypeId']) ?? current.selectedNoteTypeId,
      selectedNoteTypeName:
          m['selectedNoteTypeName']?.isNotEmpty == true
              ? m['selectedNoteTypeName']
              : current.selectedNoteTypeName,
      fieldMappings: m.containsKey('fieldMappings')
          ? Map<String, String>.from(
              jsonDecode(m['fieldMappings']!) as Map)
          : current.fieldMappings,
      tags: m['tags'] ?? current.tags,
      allowDupes: m['allowDupes'] == 'true',
      compactGlossaries: m['compactGlossaries'] == 'true',
      embedMedia: m.containsKey('embedMedia')
          ? m['embedMedia'] == 'true'
          : current.embedMedia,
    );
  }
}
