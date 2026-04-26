import 'package:hibiki/creator.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';

class AnkiHandlebar {
  AnkiHandlebar._();

  // ── Hoshi Reader 标准 Handlebar ──────────────────────────────────
  static const String expression = '{expression}';
  static const String reading = '{reading}';
  static const String furiganaPlain = '{furigana-plain}';
  static const String sentence = '{sentence}';
  static const String glossary = '{glossary}';
  static const String glossaryFirst = '{glossary-first}';
  static const String selectedGlossary = '{selected-glossary}';
  static const String documentTitle = '{document-title}';
  static const String frequencies = '{frequencies}';
  static const String frequencyHarmonicRank = '{frequency-harmonic-rank}';
  static const String pitchAccentPositions = '{pitch-accent-positions}';
  static const String pitchAccentCategories = '{pitch-accent-categories}';
  static const String bookCover = '{book-cover}';
  static const String audio = '{audio}';
  static const String sasayakiAudio = '{sasayaki-audio}';

  // ── hibiki 独有 Handlebar ────────────────────────────────────────
  static const String clozeBefore = '{cloze-before}';
  static const String clozeInside = '{cloze-inside}';
  static const String clozeAfter = '{cloze-after}';
  static const String expandedGlossary = '{expanded-glossary}';
  static const String collapsedGlossary = '{collapsed-glossary}';
  static const String hiddenGlossary = '{hidden-glossary}';
  static const String notes = '{notes}';
  static const String image = '{image}';
  static const String audioSentence = '{audio-sentence}';
  static const String tags = '{tags}';

  static const List<String> all = [
    // Hoshi 标准
    expression,
    reading,
    furiganaPlain,
    sentence,
    glossary,
    glossaryFirst,
    selectedGlossary,
    documentTitle,
    frequencies,
    frequencyHarmonicRank,
    pitchAccentPositions,
    pitchAccentCategories,
    bookCover,
    audio,
    sasayakiAudio,
    // hibiki 独有
    clozeBefore,
    clozeInside,
    clozeAfter,
    expandedGlossary,
    collapsedGlossary,
    hiddenGlossary,
    notes,
    image,
    audioSentence,
    tags,
  ];

  static const Map<String, String> _handlebarToFieldKey = {
    expression: TermField.key,
    reading: ReadingField.key,
    furiganaPlain: FuriganaField.key,
    sentence: SentenceField.key,
    glossary: MeaningField.key,
    glossaryFirst: MeaningField.key,
    selectedGlossary: MeaningField.key,
    documentTitle: ContextField.key,
    frequencies: FrequencyField.key,
    frequencyHarmonicRank: FrequencyField.key,
    pitchAccentPositions: PitchAccentField.key,
    pitchAccentCategories: PitchAccentField.key,
    bookCover: ImageField.key,
    audio: AudioField.key,
    sasayakiAudio: AudioSentenceField.key,
    clozeBefore: ClozeBeforeField.key,
    clozeInside: ClozeInsideField.key,
    clozeAfter: ClozeAfterField.key,
    expandedGlossary: ExpandedMeaningField.key,
    collapsedGlossary: CollapsedMeaningField.key,
    hiddenGlossary: HiddenMeaningField.key,
    notes: NotesField.key,
    image: ImageField.key,
    audioSentence: AudioSentenceField.key,
    tags: TagsField.key,
  };

  static const Set<String> mediaHandlebars = {
    image,
    audio,
    audioSentence,
    bookCover,
    sasayakiAudio,
  };

  static const Map<String, String> _englishNames = {
    expression: 'Expression',
    reading: 'Reading',
    furiganaPlain: 'Furigana',
    sentence: 'Sentence',
    glossary: 'Glossary',
    glossaryFirst: 'Glossary (First)',
    selectedGlossary: 'Selected Glossary',
    documentTitle: 'Document Title',
    frequencies: 'Frequencies (HTML)',
    frequencyHarmonicRank: 'Frequency (Rank)',
    pitchAccentPositions: 'Pitch Positions',
    pitchAccentCategories: 'Pitch Categories',
    bookCover: 'Book Cover',
    audio: 'Audio',
    sasayakiAudio: 'Sasayaki Audio',
    clozeBefore: 'Cloze Before',
    clozeInside: 'Cloze Inside',
    clozeAfter: 'Cloze After',
    expandedGlossary: 'Expanded Glossary',
    collapsedGlossary: 'Collapsed Glossary',
    hiddenGlossary: 'Hidden Glossary',
    notes: 'Notes',
    image: 'Image',
    audioSentence: 'Audio (Sentence)',
    tags: 'Tags',
  };

  static String _translated(String handlebar) {
    switch (handlebar) {
      case expression: return t.handlebar_expression;
      case reading: return t.handlebar_reading;
      case furiganaPlain: return t.handlebar_furigana_plain;
      case sentence: return t.handlebar_sentence;
      case glossary: return t.handlebar_glossary;
      case glossaryFirst: return t.handlebar_glossary_first;
      case selectedGlossary: return t.handlebar_selected_glossary;
      case documentTitle: return t.handlebar_document_title;
      case frequencies: return t.handlebar_frequencies;
      case frequencyHarmonicRank: return t.handlebar_frequency_harmonic_rank;
      case pitchAccentPositions: return t.handlebar_pitch_accent_positions;
      case pitchAccentCategories: return t.handlebar_pitch_accent_categories;
      case bookCover: return t.handlebar_book_cover;
      case audio: return t.handlebar_audio;
      case sasayakiAudio: return t.handlebar_sasayaki_audio;
      case clozeBefore: return t.handlebar_cloze_before;
      case clozeInside: return t.handlebar_cloze_inside;
      case clozeAfter: return t.handlebar_cloze_after;
      case expandedGlossary: return t.handlebar_expanded_glossary;
      case collapsedGlossary: return t.handlebar_collapsed_glossary;
      case hiddenGlossary: return t.handlebar_hidden_glossary;
      case notes: return t.handlebar_notes;
      case image: return t.handlebar_image;
      case audioSentence: return t.handlebar_audio_sentence;
      case tags: return t.handlebar_tags;
      default: return handlebar;
    }
  }

  static String displayName(String handlebar) {
    final en = _englishNames[handlebar] ?? handlebar;
    final localized = _translated(handlebar);
    if (en == localized) return en;
    return '$en $localized';
  }

  static List<String> resolveFieldMappings({
    required List<String> ankiFieldNames,
    required Map<String, String> fieldMappings,
    required CreatorFieldValues creatorFieldValues,
    required Map<Field, String> exportedImages,
    required Map<Field, String> exportedAudio,
    required AnkiMapping mapping,
  }) {
    return ankiFieldNames.map((ankiField) {
      final handlebar = fieldMappings[ankiField] ?? '';
      if (handlebar.isEmpty) return '';
      return _resolveHandlebar(
        handlebar: handlebar,
        creatorFieldValues: creatorFieldValues,
        exportedImages: exportedImages,
        exportedAudio: exportedAudio,
        mapping: mapping,
      );
    }).toList();
  }

  static String _resolveHandlebar({
    required String handlebar,
    required CreatorFieldValues creatorFieldValues,
    required Map<Field, String> exportedImages,
    required Map<Field, String> exportedAudio,
    required AnkiMapping mapping,
  }) {
    if (mediaHandlebars.contains(handlebar)) {
      return _resolveMedia(handlebar, exportedImages, exportedAudio, mapping);
    }

    String result = handlebar;
    final pattern = RegExp(r'\{[^}]+\}');
    result = result.replaceAllMapped(pattern, (match) {
      final tag = match.group(0)!;
      if (mediaHandlebars.contains(tag)) {
        return _resolveMedia(tag, exportedImages, exportedAudio, mapping);
      }
      return _resolveText(tag, creatorFieldValues, mapping);
    });
    return result;
  }

  static String _resolveText(
    String handlebar,
    CreatorFieldValues values,
    AnkiMapping mapping,
  ) {
    final fieldKey = _handlebarToFieldKey[handlebar];
    if (fieldKey == null) return '';

    final field = fieldsByKey[fieldKey];
    if (field == null) return '';

    String text = values.textValues[field] ?? '';

    if (handlebar == glossaryFirst && text.isNotEmpty) {
      text = text.split('\n').first;
    }

    // TODO: selectedGlossary, frequencies, pitchAccentCategories
    // 需要更丰富的数据源，目前 fallback 到同字段

    if (mapping.useBrTags ?? false) {
      text = text.replaceAll('\n', '<br>');
    }
    return text;
  }

  static String _resolveMedia(
    String handlebar,
    Map<Field, String> exportedImages,
    Map<Field, String> exportedAudio,
    AnkiMapping mapping,
  ) {
    String filename = '';
    bool isImage = false;

    switch (handlebar) {
      case image:
      case bookCover:
        filename = exportedImages[ImageField.instance] ?? '';
        isImage = true;
        break;
      case audio:
        filename = exportedAudio[AudioField.instance] ?? '';
        break;
      case audioSentence:
      case sasayakiAudio:
        filename = exportedAudio[AudioSentenceField.instance] ?? '';
        break;
    }

    if (filename.isEmpty) return '';

    if (mapping.exportMediaTags ?? false) {
      return isImage ? '<img src="$filename">' : '[sound:$filename]';
    }
    return filename;
  }

  static const Map<String, String> defaultFieldMappingsForStandardModel = {
    'Term': expression,
    'Reading': reading,
    'Furigana': furiganaPlain,
    'Sentence': sentence,
    'Cloze Before': clozeBefore,
    'Cloze Inside': clozeInside,
    'Cloze After': clozeAfter,
    'Meaning': glossary,
    'Expanded Meaning': expandedGlossary,
    'Collapsed Meaning': collapsedGlossary,
    'Notes': notes,
    'Context': documentTitle,
    'Frequency': frequencyHarmonicRank,
    'Pitch Accent': pitchAccentPositions,
    'Image': image,
    'Term Audio': audio,
    'Sentence Audio': audioSentence,
  };
}
