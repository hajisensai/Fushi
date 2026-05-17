import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../anki_models.dart';
import '../lapis_preset.dart';

class AnkiRepository {
  static const _channel = MethodChannel('app.hibiki.reader/anki');
  static const _settingsKey = 'hoshi_anki_settings';
  static const _legacyDeckKey = 'last_selected_deck';

  Future<AnkiSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_settingsKey);
    if (raw == null) {
      await _migrateFromLegacy(prefs);
      final migrated = prefs.getString(_settingsKey);
      if (migrated != null) {
        try {
          return AnkiSettings.fromJson(
              jsonDecode(migrated) as Map<String, dynamic>);
        } catch (e, stack) {
          debugPrint('AnkiRepository.loadSettings.legacy: $e\n$stack');
        }
      }
      return const AnkiSettings();
    }
    try {
      return AnkiSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e, stack) {
      debugPrint('AnkiRepository.loadSettings: $e\n$stack');
      return const AnkiSettings();
    }
  }

  Future<void> saveSettings(AnkiSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
  }

  Future<AnkiSettings> updateSettings(
      AnkiSettings Function(AnkiSettings) transform) async {
    final current = await loadSettings();
    final updated = transform(current);
    await saveSettings(updated);
    return updated;
  }

  Future<AnkiFetchResult> fetchConfiguration() async {
    try {
      await _channel.invokeMethod('requestAnkidroidPermissions');
      final decksRaw = await _channel.invokeMethod('getDecks') as Map?;
      final modelsRaw = await _channel.invokeMethod('getModelList') as Map?;
      if (decksRaw == null || modelsRaw == null) {
        return const AnkiFetchResult.error('AnkiDroid is not available.');
      }

      final decks = decksRaw.entries
          .map((e) => AnkiDeck(id: e.key as int, name: e.value as String))
          .toList();

      final noteTypes = <AnkiNoteType>[];
      for (final entry in modelsRaw.entries) {
        final name = entry.value as String;
        final fieldsRaw =
            await _channel.invokeMethod('getFieldList', {'model': name});
        final fields = List<String>.from(fieldsRaw as List? ?? []);
        noteTypes.add(
            AnkiNoteType(id: entry.key as int, name: name, fields: fields));
      }

      if (decks.isEmpty || noteTypes.isEmpty) {
        return const AnkiFetchResult.error(
            'No AnkiDroid decks or note types found.');
      }

      final updated = await updateSettings((current) {
        final selectedDeck = _selectDeckAfterFetch(decks, current);
        final selectedNoteType = _selectNoteTypeAfterFetch(noteTypes, current);
        return current.copyWith(
          selectedDeckId: selectedDeck.id,
          selectedDeckName: selectedDeck.name,
          selectedNoteTypeId: selectedNoteType.id,
          selectedNoteTypeName: selectedNoteType.name,
          availableDecks: decks,
          availableNoteTypes: noteTypes,
          fieldMappings: _fieldMappingsAfterFetch(selectedNoteType, current),
        );
      });
      return AnkiFetchResult.success(
        decks: updated.availableDecks,
        noteTypes: updated.availableNoteTypes,
      );
    } on PlatformException catch (e) {
      return AnkiFetchResult.error(e.message ??
          'Could not access AnkiDroid. Grant permission and retry.');
    }
  }

  Future<MineResult> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final settings = await loadSettings();

    final deck = settings.availableDecks
            .firstWhereOrNull((d) => d.id == settings.selectedDeckId) ??
        (settings.selectedDeckName != null
            ? settings.availableDecks
                .firstWhereOrNull((d) => d.name == settings.selectedDeckName)
            : null);
    if (deck == null) return MineResult.notConfigured;

    final noteType = settings.availableNoteTypes
            .firstWhereOrNull((t) => t.id == settings.selectedNoteTypeId) ??
        (settings.selectedNoteTypeName != null
            ? settings.availableNoteTypes.firstWhereOrNull(
                (t) => t.name == settings.selectedNoteTypeName)
            : null);
    if (noteType == null) return MineResult.notConfigured;

    final AnkiMiningPayload payload;
    try {
      final json = Map<String, dynamic>.from(jsonDecode(rawPayloadJson) as Map);
      payload = AnkiMiningPayload.fromJson(json);
    } catch (e, stack) {
      debugPrint('AnkiRepository.mineEntry.parsePayload: $e\n$stack');
      return MineResult.error;
    }

    final mediaContext = AnkiMiningContext(
      sentence: context.sentence,
      documentTitle: context.documentTitle,
      coverPath: context.coverPath != null
          ? await _addCoverImage(context.coverPath!)
          : null,
      sasayakiAudioPath: context.sasayakiAudioPath != null
          ? await _addSasayakiAudio(context.sasayakiAudioPath!)
          : null,
      sentenceOffset: context.sentenceOffset,
    );

    final rawAudio =
        payload.audio.isNotEmpty ? await _addRemoteAudio(payload.audio) : null;
    final processedAudio = rawAudio != null ? '[sound:$rawAudio]' : '';

    final mediaPayload = AnkiMiningPayload(
      expression: payload.expression,
      reading: payload.reading,
      matched: payload.matched,
      furiganaPlain: payload.furiganaPlain,
      frequenciesHtml: payload.frequenciesHtml,
      freqHarmonicRank: payload.freqHarmonicRank,
      glossary: payload.glossary,
      glossaryFirst: payload.glossaryFirst,
      singleGlossaries: payload.singleGlossaries,
      pitchPositions: payload.pitchPositions,
      pitchCategories: payload.pitchCategories,
      popupSelectionText: payload.popupSelectionText,
      audio: processedAudio,
      selectedDictionary: payload.selectedDictionary,
      dictionaryMedia: payload.dictionaryMedia,
    );

    final dictionaryMediaTags = <String, String>{};
    for (final media in payload.dictionaryMedia) {
      final tag = await _addDictionaryMedia(media);
      if (tag != null && tag.isNotEmpty) {
        dictionaryMediaTags[media.filename] = tag;
      }
    }

    final fields = <String, String>{};
    for (final entry in settings.fieldMappings.entries) {
      var value =
          AnkiHandlebarRenderer.render(entry.value, mediaPayload, mediaContext);
      for (final mediaEntry in dictionaryMediaTags.entries) {
        value = value.replaceAll(mediaEntry.key, mediaEntry.value);
      }
      value = normalizeAnkiDictionaryHtml(value);
      if (value.trim().isNotEmpty) {
        fields[entry.key] = value;
      }
    }

    if (!settings.allowDupes) {
      final firstFieldValue = noteType.fields.isNotEmpty
          ? (fields[noteType.fields.first] ?? '')
          : '';
      if (firstFieldValue.isNotEmpty) {
        final readingIdx =
            _findReadingFieldIndex(noteType, settings.fieldMappings);
        try {
          final isDupe = await _channel.invokeMethod('checkForDuplicates', {
            'models': [noteType.name],
            'key': firstFieldValue,
            'reading': payload.reading,
            'readingFieldIndices': [readingIdx],
          });
          if (isDupe == true) return MineResult.duplicate;
        } catch (e, stack) {
          debugPrint('AnkiRepository.mineEntry.dupeCheck: $e\n$stack');
        }
      }
    }

    final fieldArray = noteType.fields.map((f) => fields[f] ?? '').toList();
    final tags =
        settings.tags.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

    try {
      await _channel.invokeMethod('addNote', <String, dynamic>{
        'deck': deck.name,
        'model': noteType.name,
        'fields': fieldArray,
        'tags': tags,
      });
      return MineResult.success;
    } on PlatformException catch (e) {
      debugPrint('Failed to add note: ${e.message}');
      return MineResult.error;
    }
  }

  Future<bool> isDuplicate(String expression, String reading) async {
    final settings = await loadSettings();
    final noteType = settings.selectedNoteType;
    if (noteType == null) return false;
    final readingIdx = _findReadingFieldIndex(noteType, settings.fieldMappings);
    try {
      final result = await _channel.invokeMethod('checkForDuplicates', {
        'models': [noteType.name],
        'key': expression,
        'reading': reading,
        'readingFieldIndices': [readingIdx],
      });
      return result == true;
    } catch (e, stack) {
      debugPrint('AnkiRepository.isDuplicate: $e\n$stack');
      return false;
    }
  }

  Future<String?> _addCoverImage(String path) async {
    final raw = await _addMediaFile(
        path,
        'hibiki_cover_${File(path).uri.pathSegments.last}',
        mimeTypeForPath(path));
    return raw != null
        ? '<img src="${const HtmlEscape().convert(raw)}">'
        : null;
  }

  Future<String?> _addSasayakiAudio(String path) async {
    final raw = await _addMediaFile(
        path, File(path).uri.pathSegments.last, mimeTypeForPath(path));
    return raw != null ? '[sound:$raw]' : null;
  }

  Future<String?> _addRemoteAudio(String url) async {
    try {
      File? audioFile;
      if (url.startsWith('file://')) {
        audioFile = File(url.replaceFirst('file://', ''));
      } else if (url.startsWith('/')) {
        audioFile = File(url);
      } else if (url.startsWith('http')) {
        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(url));
          final response = await request.close();
          final bytes =
              await response.fold<List<int>>([], (a, b) => a..addAll(b));
          final cacheDir = await _mediaCacheDir();
          final urlHash = url.hashCode.toUnsigned(32).toRadixString(16);
          audioFile = File('${cacheDir.path}/hibiki_audio_$urlHash.mp3');
          await audioFile.writeAsBytes(bytes);
        } finally {
          client.close();
        }
      }
      if (audioFile == null || !audioFile.existsSync()) return null;
      return _addMediaFile(
          audioFile.path, audioFile.uri.pathSegments.last, 'audio/mpeg');
    } catch (e, stack) {
      debugPrint('AnkiRepository._addRemoteAudio: $e\n$stack');
      return null;
    }
  }

  Future<String?> _addDictionaryMedia(DictionaryMedia media) async {
    try {
      final cacheDir = await _mediaCacheDir();
      final ext = media.path.split('.').last;
      final filename = 'hibiki_dict_${media.path.hashCode}.$ext';
      final file = File('${cacheDir.path}/$filename');
      if (!file.existsSync()) return null;
      final result =
          await _addMediaFile(file.path, filename, mimeTypeForPath(media.path));
      return result != null ? ankiInlineMediaReference(result) : null;
    } catch (e, stack) {
      debugPrint('AnkiRepository._addDictionaryMedia: $e\n$stack');
      return null;
    }
  }

  Future<String?> _addMediaFile(
      String filePath, String preferredName, String mimeType) async {
    try {
      final result =
          await _channel.invokeMethod('addFileToMedia', <String, dynamic>{
        'filename': filePath,
        'preferredName': preferredName,
        'mimeType': mimeType,
      });
      return result as String?;
    } catch (e, stack) {
      debugPrint('AnkiRepository._addMediaFile $preferredName: $e\n$stack');
      return null;
    }
  }

  Future<Directory> _mediaCacheDir() async {
    final dir = Directory('${Directory.systemTemp.path}/anki-media');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  int _findReadingFieldIndex(
      AnkiNoteType noteType, Map<String, String> fieldMappings) {
    for (var i = 0; i < noteType.fields.length; i++) {
      final handlebar = fieldMappings[noteType.fields[i]] ?? '';
      if (handlebar == '{reading}') return i;
    }
    return -1;
  }

  AnkiDeck _selectDeckAfterFetch(List<AnkiDeck> decks, AnkiSettings current) =>
      decks.firstWhereOrNull((d) => d.id == current.selectedDeckId) ??
      (current.selectedDeckName != null
          ? decks.firstWhereOrNull((d) => d.name == current.selectedDeckName)
          : null) ??
      decks.firstWhereOrNull(
          (d) => !d.name.toLowerCase().startsWith('default')) ??
      decks.first;

  AnkiNoteType _selectNoteTypeAfterFetch(
          List<AnkiNoteType> noteTypes, AnkiSettings current) =>
      noteTypes.firstWhereOrNull((t) => t.id == current.selectedNoteTypeId) ??
      (current.selectedNoteTypeName != null
          ? noteTypes
              .firstWhereOrNull((t) => t.name == current.selectedNoteTypeName)
          : null) ??
      noteTypes.firstWhereOrNull(LapisPreset.matches) ??
      noteTypes.first;

  Map<String, String> _fieldMappingsAfterFetch(
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

  Future<void> _migrateFromLegacy(SharedPreferences prefs) async {
    final legacyDeck = prefs.getString(_legacyDeckKey);
    if (legacyDeck != null && legacyDeck != 'Default') {
      final settings = AnkiSettings(selectedDeckName: legacyDeck);
      await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
    }
  }
}

sealed class AnkiFetchResult {
  const AnkiFetchResult();
  const factory AnkiFetchResult.success({
    required List<AnkiDeck> decks,
    required List<AnkiNoteType> noteTypes,
  }) = AnkiFetchSuccess;
  const factory AnkiFetchResult.error(String message) = AnkiFetchError;
}

class AnkiFetchSuccess extends AnkiFetchResult {
  const AnkiFetchSuccess({required this.decks, required this.noteTypes});
  final List<AnkiDeck> decks;
  final List<AnkiNoteType> noteTypes;
}

class AnkiFetchError extends AnkiFetchResult {
  const AnkiFetchError(this.message);
  final String message;
}

enum MineResult { success, duplicate, notConfigured, error }
