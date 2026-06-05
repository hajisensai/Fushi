import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

class AnkiDeck {
  const AnkiDeck({required this.id, required this.name});

  factory AnkiDeck.fromJson(Map<String, dynamic> json) =>
      AnkiDeck(id: json['id'] as int, name: json['name'] as String);
  final int id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class AnkiNoteType {
  const AnkiNoteType({
    required this.id,
    required this.name,
    required this.fields,
  });

  factory AnkiNoteType.fromJson(Map<String, dynamic> json) => AnkiNoteType(
        id: json['id'] as int,
        name: json['name'] as String,
        fields: List<String>.from(json['fields'] as List),
      );
  final int id;
  final String name;
  final List<String> fields;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'fields': fields};
}

class AnkiSettings {
  const AnkiSettings({
    this.selectedDeckId,
    this.selectedDeckName,
    this.selectedNoteTypeId,
    this.selectedNoteTypeName,
    this.availableDecks = const [],
    this.availableNoteTypes = const [],
    this.fieldMappings = const {},
    this.tags = '',
    this.allowDupes = false,
    this.compactGlossaries = false,
    this.embedMedia = true,
    this.ankiConnectHost = 'localhost',
    this.ankiConnectPort = 8765,
    this.ankiConnectApiKey = '',
  });

  factory AnkiSettings.fromJson(Map<String, dynamic> json) => AnkiSettings(
        selectedDeckId: json['selectedDeckId'] as int?,
        selectedDeckName: json['selectedDeckName'] as String?,
        selectedNoteTypeId: json['selectedNoteTypeId'] as int?,
        selectedNoteTypeName: json['selectedNoteTypeName'] as String?,
        availableDecks: (json['availableDecks'] as List?)
                ?.map((e) => AnkiDeck.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        availableNoteTypes: (json['availableNoteTypes'] as List?)
                ?.map((e) => AnkiNoteType.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        fieldMappings:
            Map<String, String>.from(json['fieldMappings'] as Map? ?? {}),
        tags: json['tags'] as String? ?? '',
        allowDupes: json['allowDupes'] as bool? ?? false,
        compactGlossaries: json['compactGlossaries'] as bool? ?? false,
        embedMedia: json['embedMedia'] as bool? ?? true,
        ankiConnectHost: json['ankiConnectHost'] as String? ?? 'localhost',
        ankiConnectPort: json['ankiConnectPort'] as int? ?? 8765,
        ankiConnectApiKey: json['ankiConnectApiKey'] as String? ?? '',
      );
  final int? selectedDeckId;
  final String? selectedDeckName;
  final int? selectedNoteTypeId;
  final String? selectedNoteTypeName;
  final List<AnkiDeck> availableDecks;
  final List<AnkiNoteType> availableNoteTypes;
  final Map<String, String> fieldMappings;
  final String tags;
  final bool allowDupes;
  final bool compactGlossaries;
  final bool embedMedia;
  final String ankiConnectHost;
  final int ankiConnectPort;
  final String ankiConnectApiKey;

  bool get isConfigured => selectedDeckId != null && selectedNoteTypeId != null;

  AnkiNoteType? get selectedNoteType =>
      availableNoteTypes.firstWhereOrNull((t) => t.id == selectedNoteTypeId) ??
      (selectedNoteTypeName != null
          ? availableNoteTypes
              .firstWhereOrNull((t) => t.name == selectedNoteTypeName)
          : null);

  AnkiSettings copyWith({
    int? selectedDeckId,
    String? selectedDeckName,
    int? selectedNoteTypeId,
    String? selectedNoteTypeName,
    List<AnkiDeck>? availableDecks,
    List<AnkiNoteType>? availableNoteTypes,
    Map<String, String>? fieldMappings,
    String? tags,
    bool? allowDupes,
    bool? compactGlossaries,
    bool? embedMedia,
    String? ankiConnectHost,
    int? ankiConnectPort,
    String? ankiConnectApiKey,
  }) =>
      AnkiSettings(
        selectedDeckId: selectedDeckId ?? this.selectedDeckId,
        selectedDeckName: selectedDeckName ?? this.selectedDeckName,
        selectedNoteTypeId: selectedNoteTypeId ?? this.selectedNoteTypeId,
        selectedNoteTypeName: selectedNoteTypeName ?? this.selectedNoteTypeName,
        availableDecks: availableDecks ?? this.availableDecks,
        availableNoteTypes: availableNoteTypes ?? this.availableNoteTypes,
        fieldMappings: fieldMappings ?? this.fieldMappings,
        tags: tags ?? this.tags,
        allowDupes: allowDupes ?? this.allowDupes,
        compactGlossaries: compactGlossaries ?? this.compactGlossaries,
        embedMedia: embedMedia ?? this.embedMedia,
        ankiConnectHost: ankiConnectHost ?? this.ankiConnectHost,
        ankiConnectPort: ankiConnectPort ?? this.ankiConnectPort,
        ankiConnectApiKey: ankiConnectApiKey ?? this.ankiConnectApiKey,
      );

  Map<String, dynamic> toJson() => {
        'selectedDeckId': selectedDeckId,
        'selectedDeckName': selectedDeckName,
        'selectedNoteTypeId': selectedNoteTypeId,
        'selectedNoteTypeName': selectedNoteTypeName,
        'availableDecks': availableDecks.map((d) => d.toJson()).toList(),
        'availableNoteTypes':
            availableNoteTypes.map((t) => t.toJson()).toList(),
        'fieldMappings': fieldMappings,
        'tags': tags,
        'allowDupes': allowDupes,
        'compactGlossaries': compactGlossaries,
        'embedMedia': embedMedia,
        'ankiConnectHost': ankiConnectHost,
        'ankiConnectPort': ankiConnectPort,
        'ankiConnectApiKey': ankiConnectApiKey,
      };
}

class AnkiMiningPayload {
  const AnkiMiningPayload({
    required this.expression,
    this.reading = '',
    this.matched = '',
    this.furiganaPlain = '',
    this.frequenciesHtml = '',
    this.freqHarmonicRank = '',
    this.glossary = '',
    this.glossaryFirst = '',
    this.singleGlossaries = const {},
    this.pitchPositions = '',
    this.pitchCategories = '',
    this.popupSelectionText = '',
    this.audio = '',
    this.selectedDictionary = '',
    this.dictionaryMedia = const [],
  });

  factory AnkiMiningPayload.fromJson(Map<String, dynamic> json) {
    var singleGlossaries = <String, String>{};
    final sgRaw = json['singleGlossaries'];
    if (sgRaw is String && sgRaw.isNotEmpty) {
      try {
        singleGlossaries = Map<String, String>.from(jsonDecode(sgRaw) as Map);
      } catch (e, stack) {
        debugPrint('AnkiMiningPayload.singleGlossaries: $e\n$stack');
      }
    } else if (sgRaw is Map) {
      singleGlossaries = Map<String, String>.from(sgRaw);
    }

    var dictionaryMedia = <DictionaryMedia>[];
    final dmRaw = json['dictionaryMedia'];
    if (dmRaw is String && dmRaw.isNotEmpty) {
      try {
        dictionaryMedia = (jsonDecode(dmRaw) as List)
            .map((e) => DictionaryMedia.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e, stack) {
        debugPrint('AnkiMiningPayload.dictionaryMedia: $e\n$stack');
      }
    } else if (dmRaw is List) {
      dictionaryMedia = dmRaw
          .map((e) => DictionaryMedia.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    return AnkiMiningPayload(
      expression: json['expression'] as String? ?? '',
      reading: json['reading'] as String? ?? '',
      matched: json['matched'] as String? ?? '',
      furiganaPlain: json['furiganaPlain'] as String? ?? '',
      frequenciesHtml: json['frequenciesHtml'] as String? ?? '',
      freqHarmonicRank: json['freqHarmonicRank'] as String? ?? '',
      glossary: json['glossary'] as String? ?? '',
      glossaryFirst: json['glossaryFirst'] as String? ?? '',
      singleGlossaries: singleGlossaries,
      pitchPositions: json['pitchPositions'] as String? ?? '',
      pitchCategories: json['pitchCategories'] as String? ?? '',
      popupSelectionText: json['popupSelectionText'] as String? ?? '',
      audio: json['audio'] as String? ?? '',
      selectedDictionary: json['selectedDictionary'] as String? ?? '',
      dictionaryMedia: dictionaryMedia,
    );
  }
  final String expression;
  final String reading;
  final String matched;
  final String furiganaPlain;
  final String frequenciesHtml;
  final String freqHarmonicRank;
  final String glossary;
  final String glossaryFirst;
  final Map<String, String> singleGlossaries;
  final String pitchPositions;
  final String pitchCategories;
  final String popupSelectionText;
  final String audio;
  final String selectedDictionary;
  final List<DictionaryMedia> dictionaryMedia;
}

class DictionaryMedia {
  const DictionaryMedia({
    required this.dictionary,
    required this.path,
    required this.filename,
  });

  factory DictionaryMedia.fromJson(Map<String, dynamic> json) =>
      DictionaryMedia(
        dictionary: json['dictionary'] as String? ?? '',
        path: json['path'] as String? ?? '',
        filename: json['filename'] as String? ?? '',
      );
  final String dictionary;
  final String path;
  final String filename;
}

class AnkiMiningContext {
  const AnkiMiningContext({
    required this.sentence,
    this.cueSentence,
    this.documentTitle,
    this.coverPath,
    this.sasayakiAudioPath,
    this.sentenceOffset,
  });
  final String sentence;
  final String? cueSentence;
  final String? documentTitle;
  final String? coverPath;
  final String? sasayakiAudioPath;
  final int? sentenceOffset;
}

class AnkiHandlebarRenderer {
  static final _handlebarRegex = RegExp(r'\{[^}]*\}');
  static const _singleGlossaryPrefix = '{single-glossary-';

  static String render(
    String template,
    AnkiMiningPayload payload,
    AnkiMiningContext context,
  ) =>
      template.replaceAllMapped(
        _handlebarRegex,
        (match) => _handlebarToValue(match.group(0)!, payload, context),
      );

  static String _handlebarToValue(
    String handlebar,
    AnkiMiningPayload payload,
    AnkiMiningContext context,
  ) {
    if (handlebar.startsWith(_singleGlossaryPrefix)) {
      final dictionary = handlebar.substring(
          _singleGlossaryPrefix.length, handlebar.length - 1);
      return _singleGlossaryForDictionary(payload, dictionary);
    }
    switch (handlebar) {
      case '{expression}':
        return payload.expression;
      case '{reading}':
        return payload.reading;
      case '{furigana-plain}':
        return payload.furiganaPlain;
      case '{audio}':
        return payload.audio;
      case '{glossary}':
        return payload.glossary;
      case '{glossary-first}':
        return payload.glossaryFirst;
      case '{selected-glossary}':
        return _singleGlossaryForDictionary(
            payload, payload.selectedDictionary);
      case '{popup-selection-text}':
        return payload.popupSelectionText;
      case '{sentence}':
        return _sentenceValue(payload, context);
      case '{cue-sentence}':
        return _cueSentenceValue(payload, context);
      case '{frequencies}':
        return payload.frequenciesHtml;
      case '{frequency-harmonic-rank}':
        return payload.freqHarmonicRank;
      case '{pitch-accent-positions}':
        return payload.pitchPositions;
      case '{pitch-accent-categories}':
        return payload.pitchCategories;
      case '{document-title}':
        return context.documentTitle ?? '';
      case '{book-cover}':
        return context.coverPath ?? '';
      case '{sasayaki-audio}':
        return context.sasayakiAudioPath ?? '';
      default:
        return '';
    }
  }

  static String _singleGlossaryForDictionary(
    AnkiMiningPayload payload,
    String dictionary,
  ) {
    if (dictionary.isEmpty) return '';
    final direct = payload.singleGlossaries[dictionary];
    if (direct != null) return direct;
    final normalized = _normalizeDictionaryName(dictionary);
    for (final entry in payload.singleGlossaries.entries) {
      if (_normalizeDictionaryName(entry.key) == normalized) return entry.value;
    }
    return '';
  }

  static String _normalizeDictionaryName(String name) =>
      name.trim().replaceAll(RegExp(r'\s*\[[^\]]+\]\s*$'), '');

  static String _sentenceValue(
    AnkiMiningPayload payload,
    AnkiMiningContext context,
  ) {
    final matched = payload.matched;
    if (matched.isEmpty) return context.sentence;
    final offset = context.sentenceOffset;
    if (offset != null &&
        offset >= 0 &&
        offset + matched.length <= context.sentence.length &&
        context.sentence.substring(offset, offset + matched.length) ==
            matched) {
      return '${context.sentence.substring(0, offset)}'
          '<b>$matched</b>'
          '${context.sentence.substring(offset + matched.length)}';
    }
    return context.sentence.replaceFirst(matched, '<b>$matched</b>');
  }

  static String _cueSentenceValue(
    AnkiMiningPayload payload,
    AnkiMiningContext context,
  ) {
    final String text = context.cueSentence ?? context.sentence;
    final String matched = payload.matched;
    if (matched.isEmpty) return text;
    return text.replaceFirst(matched, '<b>$matched</b>');
  }
}

class AnkiHandlebarOptions {
  static const coreOptions = [
    '-',
    '{expression}',
    '{reading}',
    '{furigana-plain}',
    '{audio}',
    '{glossary}',
    '{glossary-first}',
    '{selected-glossary}',
    '{popup-selection-text}',
    '{sentence}',
    '{cue-sentence}',
    '{frequencies}',
    '{frequency-harmonic-rank}',
    '{pitch-accent-positions}',
    '{pitch-accent-categories}',
    '{document-title}',
    '{book-cover}',
    '{sasayaki-audio}',
  ];

  static List<String> forTermDictionaries(List<String> dictionaryNames) => [
        ...coreOptions,
        ...dictionaryNames.toSet().map((name) => '{single-glossary-$name}'),
      ];
}

String mimeTypeForPath(String path) {
  final ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'mp3':
      return 'audio/mpeg';
    case 'aac':
      return 'audio/aac';
    case 'm4a':
      return 'audio/mp4';
    case 'wav':
      return 'audio/wav';
    case 'ogg':
      return 'audio/ogg';
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'svg':
      return 'image/svg+xml';
    default:
      return 'application/octet-stream';
  }
}

/// Kind of audio reference resolved by [WordAudioResolver] and handed to the
/// repo media-store paths.
enum AnkiAudioRefKind { empty, remoteUrl, localFile }

/// Classifies a word-audio reference for Anki media storage, decided purely
/// from its string form so the repo audio paths are unit-testable.
///
/// `http(s)://…` is a remote URL to download; **everything else** is a local
/// file: a `file://` URI **or** a bare absolute path, Unix (`/…`) **or**
/// Windows (`C:\…`). The repo media-store helpers used to branch on
/// `file://` / `/` / `http` only and silently dropped Windows drive-letter
/// paths, so local word pronunciation never reached the card on Windows
/// (sibling of BUG-046). Treating any non-URL ref as a file removes that
/// special case instead of bolting on another `startsWith` branch.
class AnkiAudioRef {
  const AnkiAudioRef._();

  static AnkiAudioRefKind classify(String ref) {
    if (ref.isEmpty) return AnkiAudioRefKind.empty;
    if (ref.startsWith('http')) return AnkiAudioRefKind.remoteUrl;
    return AnkiAudioRefKind.localFile;
  }

  /// Resolves a [AnkiAudioRefKind.localFile] ref to a filesystem path,
  /// decoding `file://` URIs and returning bare paths unchanged.
  static String localPath(String ref) =>
      ref.startsWith('file://') ? Uri.parse(ref).toFilePath() : ref;
}

String ankiInlineMediaReference(String addMediaResult) {
  final imageSrc = RegExp(r'''<img\s+[^>]*src=["']([^"']+)["'][^>]*>''')
      .firstMatch(addMediaResult);
  if (imageSrc != null) {
    final src = imageSrc.group(1);
    if (src != null && src.isNotEmpty) return src;
  }
  final soundFile = RegExp(r'\[sound:([^\]]+)\]').firstMatch(addMediaResult);
  if (soundFile != null) {
    final file = soundFile.group(1);
    if (file != null) return file;
  }
  return addMediaResult;
}

String normalizeAnkiDictionaryHtml(String value) {
  if (!value.contains('data-sc-img') || !value.contains('gloss-image')) {
    return value;
  }
  return value + _ankiGaijiImageStyle;
}

const _ankiGaijiImageStyle = '<style>'
    '.yomitan-glossary [data-sc-img][data-sc-class="gaiji"]'
    '{display:inline!important;white-space:nowrap!important;vertical-align:baseline!important}'
    '.yomitan-glossary [data-sc-img][data-sc-class="gaiji"] .gloss-image-link'
    '{display:inline-block!important;vertical-align:text-bottom!important;max-width:1.2em!important}'
    '.yomitan-glossary [data-sc-img][data-sc-class="gaiji"] .gloss-image-container'
    '{display:inline-block!important;width:1em!important;height:1em!important;max-width:1em!important;max-height:1em!important;vertical-align:text-bottom!important;font-size:1em!important}'
    '.yomitan-glossary [data-sc-img][data-sc-class="gaiji"] .gloss-image-sizer'
    '{display:none!important}'
    '.yomitan-glossary [data-sc-img][data-sc-class="gaiji"] .gloss-image'
    '{position:static!important;width:1em!important;height:1em!important;vertical-align:text-bottom!important}'
    '</style>';

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
