import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'anki_models.dart';
import 'lapis_preset.dart';

abstract class BaseAnkiRepository {
  @protected
  static const settingsKey = 'hoshi_anki_settings';

  Future<AnkiSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(settingsKey);
    if (raw == null) return const AnkiSettings();
    try {
      return AnkiSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e, stack) {
      debugPrint('BaseAnkiRepository.loadSettings: $e\n$stack');
      return const AnkiSettings();
    }
  }

  Future<void> saveSettings(AnkiSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(settingsKey, jsonEncode(settings.toJson()));
  }

  Future<AnkiSettings> updateSettings(
      AnkiSettings Function(AnkiSettings) transform) async {
    final current = await loadSettings();
    final updated = transform(current);
    await saveSettings(updated);
    return updated;
  }

  Future<AnkiFetchResult> fetchConfiguration();

  Future<MineResult> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  });

  Future<bool> isDuplicate(String expression, String reading);

  @protected
  AnkiDeck selectDeckAfterFetch(List<AnkiDeck> decks, AnkiSettings current) =>
      decks.firstWhereOrNull((d) => d.id == current.selectedDeckId) ??
      (current.selectedDeckName != null
          ? decks.firstWhereOrNull((d) => d.name == current.selectedDeckName)
          : null) ??
      decks.firstWhereOrNull(
          (d) => !d.name.toLowerCase().startsWith('default')) ??
      decks.first;

  @protected
  AnkiNoteType selectNoteTypeAfterFetch(
          List<AnkiNoteType> noteTypes, AnkiSettings current) =>
      noteTypes.firstWhereOrNull((t) => t.id == current.selectedNoteTypeId) ??
      (current.selectedNoteTypeName != null
          ? noteTypes
              .firstWhereOrNull((t) => t.name == current.selectedNoteTypeName)
          : null) ??
      noteTypes.firstWhereOrNull(LapisPreset.matches) ??
      noteTypes.first;

  @protected
  Map<String, String> fieldMappingsAfterFetch(
      AnkiNoteType selectedNoteType, AnkiSettings current) {
    if (LapisPreset.matches(selectedNoteType) &&
        !_currentSelectionMatchesLapis(current)) {
      return LapisPreset.applyDefaults(selectedNoteType, {});
    }
    return current.fieldMappings;
  }

  bool _currentSelectionMatchesLapis(AnkiSettings current) {
    final matched = current.availableNoteTypes.firstWhereOrNull((t) =>
        t.id == current.selectedNoteTypeId ||
        t.name == current.selectedNoteTypeName);
    if (matched != null) return LapisPreset.matches(matched);
    return current.selectedNoteTypeName?.toLowerCase().contains('lapis') ??
        false;
  }
}
