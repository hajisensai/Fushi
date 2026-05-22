import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../anki_models.dart';
import '../base_anki_repository.dart';
import 'ankiconnect_service.dart';

class AnkiConnectRepository extends BaseAnkiRepository {
  AnkiConnectRepository({AnkiConnectService? service})
      : _service = service ?? AnkiConnectService();

  final AnkiConnectService _service;

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    try {
      final available = await _service.isAvailable();
      if (!available) {
        return const AnkiFetchResult.error(
            'Anki is not running or AnkiConnect plugin is not installed.\n'
            'Start Anki Desktop and install the AnkiConnect add-on (code: 2055492159).');
      }

      final deckNames = await _service.getDeckNames();
      final modelNames = await _service.getModelNames();

      if (deckNames.isEmpty || modelNames.isEmpty) {
        return const AnkiFetchResult.error(
            'No Anki decks or note types found.');
      }

      final decks = <AnkiDeck>[];
      for (var i = 0; i < deckNames.length; i++) {
        decks.add(AnkiDeck(id: i, name: deckNames[i]));
      }

      final noteTypes = <AnkiNoteType>[];
      for (var i = 0; i < modelNames.length; i++) {
        final fields = await _service.getModelFields(modelNames[i]);
        noteTypes.add(AnkiNoteType(id: i, name: modelNames[i], fields: fields));
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
    } on AnkiConnectException catch (e) {
      return AnkiFetchResult.error(e.message);
    } catch (e) {
      return AnkiFetchResult.error('Cannot connect to AnkiConnect: $e');
    }
  }

  @override
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
      debugPrint('AnkiConnectRepository.mineEntry.parsePayload: $e\n$stack');
      return MineResult.error;
    }

    final String? coverMediaRef = context.coverPath != null
        ? await _storeLocalMedia(context.coverPath!, 'hibiki_cover_')
        : null;
    final String? sasayakiMediaRef = context.sasayakiAudioPath != null
        ? await _storeLocalMedia(context.sasayakiAudioPath!, 'hibiki_audio_')
        : null;

    String processedAudio = '';
    if (payload.audio.isNotEmpty) {
      final audioRef = await _storeRemoteAudio(payload.audio);
      if (audioRef != null) processedAudio = '[sound:$audioRef]';
    }

    final mediaContext = AnkiMiningContext(
      sentence: context.sentence,
      cueSentence: context.cueSentence,
      documentTitle: context.documentTitle,
      coverPath: coverMediaRef != null ? '<img src="$coverMediaRef">' : null,
      sasayakiAudioPath:
          sasayakiMediaRef != null ? '[sound:$sasayakiMediaRef]' : null,
      sentenceOffset: context.sentenceOffset,
    );

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
      final tag = await _storeDictionaryMedia(media);
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
        try {
          final isDupe = await _service.isDuplicate(
            deckName: deck.name,
            fieldName: noteType.fields.first,
            fieldValue: firstFieldValue,
          );
          if (isDupe) return MineResult.duplicate;
        } catch (e, stack) {
          debugPrint('AnkiConnectRepository.mineEntry.dupeCheck: $e\n$stack');
        }
      }
    }

    final tags =
        settings.tags.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

    try {
      await _service.addNote(
        deckName: deck.name,
        modelName: noteType.name,
        fields: fields,
        tags: tags,
      );
      return MineResult.success;
    } on AnkiConnectException catch (e) {
      debugPrint('AnkiConnectRepository.mineEntry.addNote: $e');
      return MineResult.error;
    }
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    final settings = await loadSettings();
    final deck = settings.availableDecks
            .firstWhereOrNull((d) => d.id == settings.selectedDeckId) ??
        (settings.selectedDeckName != null
            ? settings.availableDecks
                .firstWhereOrNull((d) => d.name == settings.selectedDeckName)
            : null);
    final noteType = settings.selectedNoteType;
    if (deck == null || noteType == null || noteType.fields.isEmpty) {
      return false;
    }
    try {
      return await _service.isDuplicate(
        deckName: deck.name,
        fieldName: noteType.fields.first,
        fieldValue: expression,
      );
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository.isDuplicate: $e\n$stack');
      return false;
    }
  }

  Future<String?> _storeLocalMedia(String filePath, String prefix) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      final ext = filePath.split('.').last;
      final filename =
          '$prefix${filePath.hashCode.toUnsigned(32).toRadixString(16)}.$ext';
      await _service.storeMediaFile(
        filename: filename,
        data: base64Encode(bytes),
      );
      return filename;
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository._storeLocalMedia: $e\n$stack');
      return null;
    }
  }

  Future<String?> _storeRemoteAudio(String url) async {
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
          final cacheDir = Directory('${Directory.systemTemp.path}/anki-media');
          if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
          final urlHash = url.hashCode.toUnsigned(32).toRadixString(16);
          audioFile = File('${cacheDir.path}/hibiki_audio_$urlHash.mp3');
          await audioFile.writeAsBytes(bytes);
        } finally {
          client.close();
        }
      }
      if (audioFile == null || !audioFile.existsSync()) return null;
      final bytes = await audioFile.readAsBytes();
      final filename = audioFile.uri.pathSegments.last;
      await _service.storeMediaFile(
        filename: filename,
        data: base64Encode(bytes),
      );
      return filename;
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository._storeRemoteAudio: $e\n$stack');
      return null;
    }
  }

  Future<String?> _storeDictionaryMedia(DictionaryMedia media) async {
    try {
      final cacheDir = Directory('${Directory.systemTemp.path}/anki-media');
      final ext = media.path.split('.').last;
      final filename = 'hibiki_dict_${media.path.hashCode}.$ext';
      final file = File('${cacheDir.path}/$filename');
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      await _service.storeMediaFile(
        filename: filename,
        data: base64Encode(bytes),
      );
      final mime = mimeTypeForPath(filename);
      if (mime.startsWith('audio/')) return '[sound:$filename]';
      return '<img src="$filename">';
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository._storeDictionaryMedia: $e\n$stack');
      return null;
    }
  }
}
