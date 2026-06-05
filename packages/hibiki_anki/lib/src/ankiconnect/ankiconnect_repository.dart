import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../anki_models.dart';
import '../base_anki_repository.dart';
import '../lapis_note_type.dart';
import 'ankiconnect_service.dart';

class AnkiConnectRepository extends BaseAnkiRepository {
  AnkiConnectRepository({AnkiConnectService? service})
      : _fixedService = service;

  final AnkiConnectService? _fixedService;
  AnkiConnectService? _cachedService;
  String _cachedHost = '';
  int _cachedPort = 0;
  String _cachedApiKey = '';

  AnkiConnectService _serviceForSettings(AnkiSettings settings) {
    if (_fixedService != null) return _fixedService;
    if (_cachedService != null &&
        _cachedHost == settings.ankiConnectHost &&
        _cachedPort == settings.ankiConnectPort &&
        _cachedApiKey == settings.ankiConnectApiKey) {
      return _cachedService!;
    }
    _cachedHost = settings.ankiConnectHost;
    _cachedPort = settings.ankiConnectPort;
    _cachedApiKey = settings.ankiConnectApiKey;
    _cachedService = AnkiConnectService(
      host: settings.ankiConnectHost,
      port: settings.ankiConnectPort,
      apiKey: settings.ankiConnectApiKey,
    );
    return _cachedService!;
  }

  Future<AnkiConnectService> _getService() async =>
      _serviceForSettings(await loadSettings());

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    try {
      final service = await _getService();
      final connectionError = await service.checkConnection();
      if (connectionError != null) {
        return AnkiFetchResult.error(connectionError);
      }

      final deckNames = await service.getDeckNames();
      final modelNames = await service.getModelNames();

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
        final fields = await service.getModelFields(modelNames[i]);
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
    final service = _serviceForSettings(settings);

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
        ? await _storeLocalMedia(service, context.coverPath!, 'hibiki_cover_')
        : null;
    final String? sasayakiMediaRef = context.sasayakiAudioPath != null
        ? await _storeLocalMedia(
            service, context.sasayakiAudioPath!, 'hibiki_audio_')
        : null;

    String processedAudio = '';
    if (payload.audio.isNotEmpty) {
      final audioRef = await _storeRemoteAudio(service, payload.audio);
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
      final tag = await _storeDictionaryMedia(service, media);
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
        // HBK-AUDIT-060: fail closed. A failed dupe query must not fall through
        // to addNote as if the entry were unique — that silently bypasses the
        // no-duplicates guarantee. Surface the failure as an error instead.
        try {
          final isDupe = await service.isDuplicate(
            deckName: deck.name,
            fieldName: noteType.fields.first,
            fieldValue: firstFieldValue,
          );
          if (isDupe) return MineResult.duplicate;
        } catch (e, stack) {
          debugPrint('AnkiConnectRepository.mineEntry.dupeCheck: $e\n$stack');
          return MineResult.error;
        }
      }
    }

    final tags =
        settings.tags.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

    // `fields` only holds entries that rendered to a non-empty value; if it is
    // empty, nothing rendered and adding the note would create a blank card
    // reported as success (HBK-AUDIT-018).
    if (fields.isEmpty) {
      debugPrint(
          'AnkiConnectRepository.mineEntry: all fields empty, refusing blank note');
      return MineResult.error;
    }
    try {
      await service.addNote(
        deckName: deck.name,
        modelName: noteType.name,
        fields: fields,
        tags: tags,
        allowDuplicate: settings.allowDupes,
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
      final service = _serviceForSettings(settings);
      return await service.isDuplicate(
        deckName: deck.name,
        fieldName: noteType.fields.first,
        fieldValue: expression,
      );
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository.isDuplicate: $e\n$stack');
      return false;
    }
  }

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async {
    final service = await _getService();
    final existing = await service.getModelNames();
    if (existing.contains(template.name)) return false;
    await service.createModel(template);
    return true;
  }

  @override
  Future<bool> createDeck(String name) async {
    final service = await _getService();
    final existing = await service.getDeckNames();
    if (existing.contains(name)) return false;
    await service.createDeck(name);
    return true;
  }

  Future<String?> _storeLocalMedia(
    AnkiConnectService service,
    String filePath,
    String prefix,
  ) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      final ext = filePath.split('.').last;
      final filename =
          '$prefix${filePath.hashCode.toUnsigned(32).toRadixString(16)}.$ext';
      await service.storeMediaFile(
        filename: filename,
        data: base64Encode(bytes),
      );
      return filename;
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository._storeLocalMedia: $e\n$stack');
      return null;
    }
  }

  Future<String?> _storeRemoteAudio(
      AnkiConnectService service, String url) async {
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
          // A non-200 returns an HTML/JSON error body; writing it verbatim to
          // .mp3 would embed a broken "audio" file into the card
          // (HBK-AUDIT-019).
          if (response.statusCode != 200) {
            debugPrint(
                'AnkiConnectRepository._storeRemoteAudio: HTTP ${response.statusCode} for $url');
            return null;
          }
          final bytes =
              await response.fold<List<int>>([], (a, b) => a..addAll(b));
          final cacheDir = Directory('${Directory.systemTemp.path}/anki-media');
          if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
          final urlHash = url.hashCode.toUnsigned(32).toRadixString(16);
          // HBK-AUDIT-062: derive the real extension from the response
          // Content-Type (falling back to the URL path, then mp3) so non-mp3
          // audio is not mislabeled as .mp3 in Anki.
          final ext = _audioExtension(response.headers.contentType, url);
          audioFile = File('${cacheDir.path}/hibiki_audio_$urlHash.$ext');
          await audioFile.writeAsBytes(bytes);
        } finally {
          client.close();
        }
      }
      if (audioFile == null || !audioFile.existsSync()) return null;
      final bytes = await audioFile.readAsBytes();
      final filename = audioFile.uri.pathSegments.last;
      await service.storeMediaFile(
        filename: filename,
        data: base64Encode(bytes),
      );
      return filename;
    } catch (e, stack) {
      debugPrint('AnkiConnectRepository._storeRemoteAudio: $e\n$stack');
      return null;
    }
  }

  /// HBK-AUDIT-062: resolve a remote audio file extension from the response
  /// Content-Type, falling back to the URL path extension, then `mp3`.
  String _audioExtension(ContentType? contentType, String url) {
    switch (contentType?.mimeType) {
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/aac':
        return 'aac';
      case 'audio/mp4':
      case 'audio/x-m4a':
        return 'm4a';
      case 'audio/wav':
      case 'audio/x-wav':
        return 'wav';
      case 'audio/ogg':
      case 'audio/opus':
        return 'ogg';
      case 'audio/webm':
        return 'webm';
      case 'audio/flac':
      case 'audio/x-flac':
        return 'flac';
    }
    // Fall back to the extension embedded in the URL path, then mp3.
    final path = Uri.tryParse(url)?.path ?? url;
    final lastDot = path.lastIndexOf('.');
    final lastSlash = path.lastIndexOf('/');
    if (lastDot > lastSlash && lastDot < path.length - 1) {
      return path.substring(lastDot + 1).toLowerCase();
    }
    return 'mp3';
  }

  Future<String?> _storeDictionaryMedia(
    AnkiConnectService service,
    DictionaryMedia media,
  ) async {
    try {
      final cacheDir = Directory('${Directory.systemTemp.path}/anki-media');
      // HBK-AUDIT-062: split('.').last returns the whole path when there is no
      // dot, producing a bogus extension. Guard for the no-extension case.
      final lastDot = media.path.lastIndexOf('.');
      final ext = (lastDot >= 0 && lastDot < media.path.length - 1)
          ? media.path.substring(lastDot + 1)
          : 'bin';
      final filename = 'hibiki_dict_${media.path.hashCode}.$ext';
      final file = File('${cacheDir.path}/$filename');
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      await service.storeMediaFile(
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
