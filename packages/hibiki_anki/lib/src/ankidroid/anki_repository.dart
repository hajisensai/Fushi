import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../anki_models.dart';
import '../base_anki_repository.dart';
import '../lapis_note_type.dart';

class AnkiRepository extends BaseAnkiRepository {
  static const _channel = MethodChannel('app.hibiki.reader/anki');
  static const _legacyDeckKey = 'last_selected_deck';

  @override
  Future<AnkiSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(BaseAnkiRepository.settingsKey);
    if (raw == null) {
      await _migrateFromLegacy(prefs);
      final migrated = prefs.getString(BaseAnkiRepository.settingsKey);
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

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    try {
      await _channel.invokeMethod('requestAnkidroidPermissions');
      final decksRaw = await _channel.invokeMethod('getDecks') as Map?;
      final modelsRaw = await _channel.invokeMethod('getModelList') as Map?;
      if (decksRaw == null || modelsRaw == null) {
        return const AnkiFetchResult.error('AnkiDroid is not available.');
      }

      // HBK-AUDIT-063: AnkiDroid deck/model ids are 13-digit epoch longs. The
      // StandardMessageCodec normally decodes them as Dart int, but a JSON
      // string id (or any contract drift) would make an unchecked `as int`
      // throw a CastError that escapes the PlatformException-only catch. Parse
      // ids and names defensively instead.
      final decks = decksRaw.entries
          .map((e) =>
              AnkiDeck(id: _asInt(e.key), name: e.value?.toString() ?? ''))
          .toList();

      final noteTypes = <AnkiNoteType>[];
      for (final entry in modelsRaw.entries) {
        final name = entry.value?.toString() ?? '';
        final fieldsRaw =
            await _channel.invokeMethod('getFieldList', {'model': name});
        final fields = List<String>.from(fieldsRaw as List? ?? []);
        noteTypes.add(
            AnkiNoteType(id: _asInt(entry.key), name: name, fields: fields));
      }

      if (decks.isEmpty || noteTypes.isEmpty) {
        return const AnkiFetchResult.error(
            'No AnkiDroid decks or note types found.');
      }

      final updated = await updateSettings((current) {
        final selectedDeck = selectDeckAfterFetch(decks, current);
        final selectedNoteType = selectNoteTypeAfterFetch(noteTypes, current);
        return current.copyWith(
          selectedDeckId: selectedDeck.id,
          selectedDeckName: selectedDeck.name,
          selectedNoteTypeId: selectedNoteType.id,
          selectedNoteTypeName: selectedNoteType.name,
          availableDecks: decks,
          availableNoteTypes: noteTypes,
          fieldMappings: fieldMappingsAfterFetch(selectedNoteType, current),
        );
      });
      return AnkiFetchResult.success(
        decks: updated.availableDecks,
        noteTypes: updated.availableNoteTypes,
      );
    } on PlatformException catch (e) {
      return AnkiFetchResult.error(e.message ??
          'Could not access AnkiDroid. Grant permission and retry.');
    } catch (e, stack) {
      // HBK-AUDIT-063: a malformed/typed channel response (TypeError,
      // FormatException, etc.) must not crash the fetch out of the provider;
      // surface it as a fetch error instead.
      debugPrint('AnkiRepository.fetchConfiguration: $e\n$stack');
      return const AnkiFetchResult.error(
          'Unexpected response from AnkiDroid. Update AnkiDroid and retry.');
    }
  }

  /// HBK-AUDIT-063: coerce an untyped platform-channel id to int. AnkiDroid
  /// deck/model ids are epoch-based longs; accept either a Dart int or a
  /// stringified long without throwing an uncaught CastError.
  static int _asInt(Object? value) {
    if (value is int) return value;
    return int.parse(value.toString());
  }

  // BUG-077: mirror AnkiConnectRepository — never let mineEntry throw. The
  // popup mine button disables itself and awaits this Future; an escape would
  // hang the '+' with no toast. Convert any unhandled error into
  // MineResult.error so the caller's switch always runs.
  //
  // BUG-089: carry the real cause back to the UI via MineOutcome (errorDetail
  // for the toast, error/stackTrace for ErrorLogService) instead of swallowing
  // it in debugPrint.
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    try {
      return await _mineEntryInner(
        rawPayloadJson: rawPayloadJson,
        context: context,
      );
    } catch (e, stack) {
      return MineOutcome.failure(
        'AnkiDroid: unexpected error: $e',
        error: e,
        stackTrace: stack,
      );
    }
  }

  Future<MineOutcome> _mineEntryInner({
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
    if (deck == null) return const MineOutcome.notConfigured();

    final noteType = settings.availableNoteTypes
            .firstWhereOrNull((t) => t.id == settings.selectedNoteTypeId) ??
        (settings.selectedNoteTypeName != null
            ? settings.availableNoteTypes.firstWhereOrNull(
                (t) => t.name == settings.selectedNoteTypeName)
            : null);
    if (noteType == null) return const MineOutcome.notConfigured();

    final AnkiMiningPayload payload;
    try {
      final json = Map<String, dynamic>.from(jsonDecode(rawPayloadJson) as Map);
      payload = AnkiMiningPayload.fromJson(json);
    } catch (e, stack) {
      return MineOutcome.failure(
        'Invalid card data (payload parse failed): $e',
        error: e,
        stackTrace: stack,
      );
    }

    final mediaContext = AnkiMiningContext(
      sentence: context.sentence,
      cueSentence: context.cueSentence,
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
          if (isDupe == true) return const MineOutcome.duplicate();
        } catch (e, stack) {
          debugPrint('AnkiRepository.mineEntry.dupeCheck: $e\n$stack');
        }
      }
    }

    final fieldArray = noteType.fields.map((f) => fields[f] ?? '').toList();
    // AddContentApi accepts an array of empty strings and creates a blank note
    // that the channel reports as success. Refuse if nothing rendered into any
    // field (HBK-AUDIT-018).
    if (fieldArray.every((v) => v.trim().isEmpty)) {
      return MineOutcome.failure(
        'All fields are empty — refusing to create a blank card. '
        'Check your note type field mappings.',
      );
    }
    final tags =
        settings.tags.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

    try {
      await _channel.invokeMethod('addNote', <String, dynamic>{
        'deck': deck.name,
        'model': noteType.name,
        'fields': fieldArray,
        'tags': tags,
      });
      return const MineOutcome.success();
    } on PlatformException catch (e, stack) {
      return MineOutcome.failure(
        'AnkiDroid: ${e.message ?? e.code}',
        error: e,
        stackTrace: stack,
      );
    }
  }

  @override
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

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async {
    await _channel.invokeMethod('requestAnkidroidPermissions');
    final models = await _channel.invokeMethod('getModelList') as Map?;
    final exists =
        models?.values.any((v) => v?.toString() == template.name) ?? false;
    if (exists) return false;
    await _channel.invokeMethod('createNoteType', <String, dynamic>{
      'noteTypeName': template.name,
      'noteTypeFields': template.fields,
      'cardName': template.cardName,
      'front': template.front,
      'back': template.back,
      'css': template.css,
    });
    return true;
  }

  @override
  Future<bool> createDeck(String name) async {
    await _channel.invokeMethod('requestAnkidroidPermissions');
    final decks = await _channel.invokeMethod('getDecks') as Map?;
    final exists = decks?.values.any((v) => v?.toString() == name) ?? false;
    if (exists) return false;
    await _channel.invokeMethod('createDeck', <String, dynamic>{
      'deckName': name,
    });
    return true;
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
      switch (AnkiAudioRef.classify(url)) {
        case AnkiAudioRefKind.empty:
          return null;
        case AnkiAudioRefKind.localFile:
          // file:// URI or a bare absolute path (Unix `/…` or Windows `C:\…`).
          audioFile = File(AnkiAudioRef.localPath(url));
        case AnkiAudioRefKind.remoteUrl:
          final client = HttpClient();
          try {
            final request = await client.getUrl(Uri.parse(url));
            final response = await request.close();
            // A non-200 returns an HTML/JSON error body; writing it verbatim to
            // .mp3 would embed a broken "audio" file into the card
            // (HBK-AUDIT-019).
            if (response.statusCode != 200) {
              debugPrint(
                  'AnkiRepository._addRemoteAudio: HTTP ${response.statusCode} for $url');
              return null;
            }
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
      // Every switch branch above either returns or assigns audioFile, so it is
      // non-null here; only existence can still fail (missing local file or a
      // download that produced no file).
      if (!audioFile.existsSync()) return null;
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

  Future<void> _migrateFromLegacy(SharedPreferences prefs) async {
    final legacyDeck = prefs.getString(_legacyDeckKey);
    if (legacyDeck != null && legacyDeck != 'Default') {
      final settings = AnkiSettings(selectedDeckName: legacyDeck);
      await prefs.setString(
          BaseAnkiRepository.settingsKey, jsonEncode(settings.toJson()));
    }
  }
}
