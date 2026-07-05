import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:url_launcher/url_launcher.dart';

typedef AnkiMobileUrlOpener = Future<bool> Function(Uri uri);
typedef AnkiMobileInfoReader = Future<String?> Function();

const String ankiMobileInfoCallback = 'anki://x-callback-url/infoForAdding';
const String ankiMobileAddNoteCallback = 'anki://x-callback-url/addnote';
const String hibikiAnkiFetchCallback = 'hibiki://ankiFetch';
const String hibikiAnkiSuccessCallback = 'hibiki://ankiSuccess';

const MethodChannel _ankiMobileChannel =
    MethodChannel('app.hibiki.reader/ankimobile');

String _encodeAnkiMobileQueryComponent(String value) =>
    Uri.encodeComponent(value);

String _buildAnkiMobileQuery(Iterable<MapEntry<String, String>> entries) {
  return entries
      .map((entry) => '${_encodeAnkiMobileQueryComponent(entry.key)}='
          '${_encodeAnkiMobileQueryComponent(entry.value)}')
      .join('&');
}

Uri buildAnkiMobileAddNoteUri({
  required String deckName,
  required String noteTypeName,
  required Map<String, String> fields,
  required List<String> tags,
  required bool allowDuplicate,
  Uri? successCallback,
}) {
  final query = <MapEntry<String, String>>[
    MapEntry('deck', deckName),
    MapEntry('type', noteTypeName),
    for (final entry in fields.entries)
      MapEntry('fld${entry.key}', entry.value),
    if (tags.isNotEmpty) MapEntry('tags', tags.join(' ')),
    if (allowDuplicate) const MapEntry('dupes', '1'),
    if (successCallback != null)
      MapEntry('x-success', successCallback.toString()),
  ];
  return Uri.parse(
      '$ankiMobileAddNoteCallback?${_buildAnkiMobileQuery(query)}');
}

class AnkiMobileRepository extends BaseAnkiRepository {
  AnkiMobileRepository({
    AnkiMobileUrlOpener? openUrl,
    AnkiMobileInfoReader? readInfoForAddingJson,
  })  : _openUrl = openUrl ?? _openExternalUrl,
        _readInfoForAddingJson =
            readInfoForAddingJson ?? _readInfoForAddingJsonFromPlatform;

  final AnkiMobileUrlOpener _openUrl;
  final AnkiMobileInfoReader _readInfoForAddingJson;

  static Future<bool> _openExternalUrl(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  static Future<String?> _readInfoForAddingJsonFromPlatform() =>
      _ankiMobileChannel.invokeMethod<String>('consumeInfoForAddingPasteboard');

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    final uri = Uri.parse(ankiMobileInfoCallback).replace(
      queryParameters: const <String, String>{
        'x-success': hibikiAnkiFetchCallback,
      },
    );
    final opened = await _openUrl(uri);
    if (!opened) {
      return const AnkiFetchResult.error(
        'Could not open AnkiMobile. Install AnkiMobile and try again.',
      );
    }
    return const AnkiFetchResult.error(
      'AnkiMobile opened. Approve the request, then return to Hibiki.',
    );
  }

  Future<AnkiFetchResult> consumeInfoForAddingPasteboard() async {
    final raw = await _readInfoForAddingJson();
    if (raw == null || raw.trim().isEmpty) {
      return const AnkiFetchResult.error(
        'No AnkiMobile configuration was found on the clipboard.',
      );
    }

    final AnkiMobileInfoForAdding info;
    try {
      info = AnkiMobileInfoForAdding.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e) {
      return AnkiFetchResult.error('Could not read AnkiMobile response: $e');
    }

    if (info.decks.isEmpty || info.noteTypes.isEmpty) {
      return const AnkiFetchResult.error(
        'AnkiMobile returned no decks or note types.',
      );
    }

    final updated = await updateSettings((current) {
      final selectedDeck = selectDeckAfterFetch(info.decks, current);
      final selectedNoteType =
          selectNoteTypeAfterFetch(info.noteTypes, current);
      return current.copyWith(
        selectedDeckId: selectedDeck.id,
        selectedDeckName: selectedDeck.name,
        selectedNoteTypeId: selectedNoteType.id,
        selectedNoteTypeName: selectedNoteType.name,
        availableDecks: info.decks,
        availableNoteTypes: info.noteTypes,
        fieldMappings: fieldMappingsAfterFetch(selectedNoteType, current),
      );
    });

    return AnkiFetchResult.success(
      decks: updated.availableDecks,
      noteTypes: updated.availableNoteTypes,
    );
  }

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
        'AnkiMobile: unexpected error.',
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
      payload = AnkiMiningPayload.fromJson(
        Map<String, dynamic>.from(jsonDecode(rawPayloadJson) as Map),
      );
    } catch (e, stack) {
      return MineOutcome.failure(
        'Invalid card data (payload parse failed): $e',
        error: e,
        stackTrace: stack,
      );
    }

    final fields = buildMinedFields(
      fieldMappings: settings.fieldMappings,
      payload: payload,
      context: context,
      dictionaryMediaTags: const <String, String>{},
    );
    if (fields.isEmpty) {
      return MineOutcome.failure(
        'All fields are empty — refusing to create a blank card. '
        'Check your note type field mappings.',
      );
    }

    final tags = buildNoteTags(
      settings.tags,
      source: context.source,
      includeHibiki: settings.tagIncludeHibiki,
      includeCategory: settings.tagIncludeCategory,
      titleTag: context.bookTitleTag,
    );
    final success = Uri.parse(hibikiAnkiSuccessCallback).replace(
      queryParameters: <String, String>{
        if (payload.expression.isNotEmpty) 'expression': payload.expression,
      },
    );
    final uri = buildAnkiMobileAddNoteUri(
      deckName: deck.name,
      noteTypeName: noteType.name,
      fields: fields,
      tags: tags,
      allowDuplicate: settings.allowDupes,
      successCallback: success,
    );

    final opened = await _openUrl(uri);
    if (!opened) {
      return MineOutcome.failure(
        'Could not open AnkiMobile. Install AnkiMobile and try again.',
      );
    }
    return const MineOutcome.success();
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

class AnkiMobileInfoForAdding {
  const AnkiMobileInfoForAdding({
    required this.decks,
    required this.noteTypes,
  });

  factory AnkiMobileInfoForAdding.fromJson(Map<String, dynamic> json) {
    final decksRaw = (json['decks'] as List? ?? const <Object?>[]);
    final noteTypesRaw = (json['notetypes'] as List? ?? const <Object?>[]);
    final decks = <AnkiDeck>[
      for (var i = 0; i < decksRaw.length; i++)
        AnkiDeck(
          id: i,
          name: _nameFromJsonItem(decksRaw[i]),
        ),
    ].where((deck) => deck.name.isNotEmpty).toList(growable: false);
    final noteTypes = <AnkiNoteType>[
      for (var i = 0; i < noteTypesRaw.length; i++)
        _noteTypeFromJsonItem(i, noteTypesRaw[i]),
    ].where((noteType) => noteType.name.isNotEmpty).toList(growable: false);
    return AnkiMobileInfoForAdding(decks: decks, noteTypes: noteTypes);
  }

  final List<AnkiDeck> decks;
  final List<AnkiNoteType> noteTypes;

  static AnkiNoteType _noteTypeFromJsonItem(int id, Object? raw) {
    if (raw is! Map) {
      return AnkiNoteType(
          id: id, name: raw?.toString() ?? '', fields: const []);
    }
    final fieldsRaw = raw['fields'] as List? ?? const <Object?>[];
    return AnkiNoteType(
      id: id,
      name: raw['name']?.toString() ?? '',
      fields: fieldsRaw
          .map(_nameFromJsonItem)
          .where((field) => field.isNotEmpty)
          .toList(growable: false),
    );
  }

  static String _nameFromJsonItem(Object? raw) {
    if (raw is Map) return raw['name']?.toString() ?? '';
    return raw?.toString() ?? '';
  }
}
