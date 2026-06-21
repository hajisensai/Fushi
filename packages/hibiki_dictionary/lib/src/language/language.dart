import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../engine/hoshidicts.dart';
import '../formats/dictionary_format.dart';
import '../models/dictionary_entry.dart';
import '../models/dictionary_operations_params.dart';
import '../models/dictionary_search_result.dart';
import 'language_utils.dart';

/// Defines common characteristics required for tuning locale and text
/// segmentation behaviour for different languages. Override the variables
/// and functions of this abstract class in order to implement a target
/// language.
abstract class Language {
  /// Initialise the language with the required details.
  Language({
    required this.languageName,
    required this.languageCode,
    required this.threeLetterCode,
    required this.countryCode,
    required this.textDirection,
    required this.preferVerticalReading,
    required this.isSpaceDelimited,
    required this.textBaseline,
    required this.helloWorld,
    required this.standardFormat,
    required this.defaultFontFamily,
    this.prepareSearchResults = prepareSearchResultsStandard,
  });

  /// The name of the language, as known to native speakers.
  ///
  /// For example, in the case of Japanese, this is '日本語'.
  /// In the case of American English, this is 'English (US)'.
  final String languageName;

  /// The ISO 639-1 code or the international standard language code.
  ///
  /// For example, in the case of Japanese, this is 'ja'.
  /// In the case of English, this is 'en'.
  final String languageCode;

  /// The ISO 639-3 code or the international standard language code.
  ///
  /// For example, in the case of Japanese, this is 'jpn'.
  /// In the case of English, this is 'eng'.
  final String threeLetterCode;

  /// The ISO 3166-1 code or the international standard name of country.
  ///
  /// For example, in the case of Japanese, this is 'JP'.
  /// In the case of (American) English, this is 'US'.
  final String countryCode;

  /// The reading direction of the language, for which reading should be
  /// given a specific format by default. For example, Arabic is RTL, while
  /// English is LTR.
  final TextDirection textDirection;

  /// Whether or not this language should prefer vertical reading.
  final bool preferVerticalReading;

  /// Whether or not this language essentially relies on spaces to  commonly
  /// separate and discern words.
  final bool isSpaceDelimited;

  /// If this language uses an alphabetic or ideographic text baseline.
  final TextBaseline textBaseline;

  /// Testing text for the language's basic use. This is useful for testing
  /// and pre-loading the database for use.
  final String helloWorld;

  /// Overrides the base search function and implements search specific to
  /// a language.
  final Future<DictionarySearchResult?> Function(DictionarySearchParams params)
      prepareSearchResults;

  /// Direct search using the HoshiDicts singleton (no isolate).
  DictionarySearchResult? prepareSearchResultsDirect({
    required String searchTerm,
    required int maximumDictionarySearchResults,
    required int maximumDictionaryTermsInResult,
  }) {
    return prepareSearchResultsDirectStandard(
      searchTerm: searchTerm,
      maximumDictionarySearchResults: maximumDictionarySearchResults,
      maximumDictionaryTermsInResult: maximumDictionaryTermsInResult,
    );
  }

  /// A standard format that dictionaries of this language can be found in.
  /// This is only to set this as the default last selected format on first
  /// time setup.
  final DictionaryFormat standardFormat;

  /// Default font for a language.
  final String defaultFontFamily;

  /// Whether or not [initialise] has been called for the language.
  bool _initialised = false;

  /// Some implementations of tap-to-select are very unoptimised for a high
  /// length of text. It is impractical to run text segmentation in some cases.
  /// This value sets a length from the center from which input text for
  /// [wordFromIndex] should be cut if longer. If null, the limit will not be
  /// used.
  int? indexMaxDistance;

  /// This function is run at startup or when changing languages. It is not
  /// called again if already run.
  Future<void> initialise() async {
    if (_initialised) {
      return;
    } else {
      await prepareResources();
      _initialised = true;
    }
  }

  /// Extract a [Locale] from the language code and country code.
  Locale get locale => Locale(languageCode, countryCode);

  /// Prepare text segmentation tools and other dependencies necessary for this
  /// langauge to function.
  Future<void> prepareResources();

  /// Given paragraph text and an index, yield the part of the text such that
  /// the result is a sentence. Different languages may decide to use different
  /// delimiters.
  HibikiTextSelection getSentenceFromParagraph({
    required String paragraph,
    required int index,
    required int startOffset,
    required int endOffset,
  }) {
    List<String> sentences = getSentences(paragraph);
    int currentIndex = 0;
    String sentenceToReturn = paragraph;

    int sentenceLength = 0;

    for (String sentence in sentences) {
      sentenceToReturn = sentence;
      sentenceLength = sentence.length;

      currentIndex += sentenceLength;
      if (currentIndex > index) {
        break;
      }
    }

    final int rawStart = sentenceLength - currentIndex + startOffset;
    final int rawEnd = sentenceLength - currentIndex + endOffset;
    TextRange range = TextRange(
      start: rawStart.clamp(0, sentenceToReturn.length),
      end: rawEnd.clamp(0, sentenceToReturn.length),
    );
    return HibikiTextSelection(
      text: sentenceToReturn,
      range: range,
    );
  }

  /// Returns a list of sentences for a block of text.
  List<String> getSentences(String text) {
    RegExp regex = RegExp(r'.{1,}?([。.?？!！]+|\n)');

    Iterable<Match> matches = regex.allMatches(text);

    if (matches.isEmpty) {
      return [text];
    }

    List<String> sentences = regex.allMatchesWithSep(text);

    return sentences;
  }

  /// The language and country code separated by a dash.
  String get languageCountryCode => '$languageCode-$countryCode';

  /// Given unsegmented [text], perform text segmentation particular to the
  /// language and return a list of parsed words.
  ///
  /// For example, in the case of Japanese, '日本語は難しいです。', this should
  /// ideally return a list containing '日本語', 'は', '難しい', 'です', '。'.
  ///
  /// In the case of English, 'This is a pen.' should ideally return a list
  /// containing 'This', ' ', 'is', ' ', 'a', ' ', 'pen', '.'. Delimiters
  /// should stay intact for languages that feature such, such as spaces.
  List<String> textToWords(String text);

  /// Given an [index] or a character position in given [text], return a word
  /// such that it corresponds to a whole word from the parsed list of words
  /// from [textToWords].
  ///
  /// For example, in the case of Japanese, the parameters '日本語は難しいです。'
  /// and given index 2 (語), this should be '日本語'.
  ///
  /// In the case of English, 'This is a pen.' at index 10 (p), should return
  /// the word 'pen'.
  String wordFromIndex({
    required String text,
    required int index,
  }) {
    /// See [indexMaxDistance] above.
    /// If the [indexMaxDistance] is not defined...
    if (indexMaxDistance != null) {
      /// If the length of text cut into two, incrmeented by one exceeds the
      /// [indexMaxDistance] multiplied into two and incremented by one...
      if (((text.length / 2) + 1) > ((indexMaxDistance! * 2) + 1)) {
        /// Then get a substring of text, with the original index character
        /// being the center and to its left and right, a maximum number of
        /// [indexMaxDistance] characters...
        ///
        /// Of course, the indexes of those values will have to be in the range
        /// of (0, length - 1)...
        List<int> originalIndexTape = [];
        List<int> indexTape = [];

        int rangeStart = max(0, index - indexMaxDistance!);
        int rangeEnd = min(text.length - 1, index + indexMaxDistance! + 1);

        for (int i = 0; i < text.length; i++) {
          originalIndexTape.add(i);
        }

        StringBuffer buffer = StringBuffer();
        int newIndex = -1;

        for (int i = 0; i < text.runes.length; i++) {
          if (i >= rangeStart && i < rangeEnd) {
            final String character =
                String.fromCharCode(text.runes.elementAt(i));
            buffer.write(character);

            indexTape.add(i);
            if (index == i) {
              newIndex = indexTape.indexOf(i);
            }
          }
        }

        final String newText = buffer.toString();

        return wordFromIndex(text: newText, index: newIndex);
      }
    }

    List<String> words = textToWords(text);

    List<String> wordTape = [];
    for (int i = 0; i < words.length; i++) {
      String word = words[i];
      for (int j = 0; j < word.length; j++) {
        wordTape.add(word);
      }
    }

    if (index < 0 || index >= wordTape.length) return '';
    String word = wordTape[index];

    return word;
  }

  /// Gets a search term and for a space-delimited language, assumes the index
  /// is within the range of the first word, with remainder words included.
  /// For a language that is not space-delimited, this is simply the substring
  /// function.
  String getSearchTermFromIndex({
    required String text,
    required int index,
  }) {
    if (isSpaceDelimited) {
      final workingBuffer = StringBuffer();
      final termBuffer = StringBuffer();
      List<String> words = textToWords(text.replaceAll('\n', ' '));

      for (String word in words) {
        workingBuffer.write(word);
        if (workingBuffer.length > index) {
          termBuffer.write(word);
        }
      }

      return termBuffer.toString();
    } else {
      if (index < 0 || index >= text.length) return '';
      return text.substring(index);
    }
  }

  /// Returns the starting index from which the search term should be chopped
  /// from, given a clicked index and full text. For a space-delimited language,
  /// this will return the starting index of a clicked word. Otherwise, this
  /// returns the clicked index itself.
  TextRange getWordRange({
    required HibikiTextSelection selection,
  }) {
    final workingBuffer = StringBuffer();
    String selectedWord = '';
    int start = 0;

    List<String> words = textToWords(selection.text.replaceAll('\n', ' '));

    for (String word in words) {
      workingBuffer.write(word);
      selectedWord = word;

      if (workingBuffer.length > selection.range.start) {
        start = workingBuffer.length - word.length;
        break;
      }
    }

    int end = start + selectedWord.length;

    return TextRange(start: start, end: end);
  }

  /// Get preliminary highlight length before a dictionary search.
  HibikiTextSelection getGuessHighlight({
    required HibikiTextSelection selection,
  }) {
    return HibikiTextSelection(
      text: selection.text,
      range: getWordRange(selection: selection),
    );
  }

  /// Get preliminary highlight length before a dictionary search.
  int getGuessHighlightLength({
    required String searchTerm,
  }) {
    final truncated =
        searchTerm.length > 40 ? searchTerm.substring(0, 40) : searchTerm;
    final word = textToWords(truncated)
        .firstWhere((e) => e.trim().isNotEmpty, orElse: () => '');
    final length = word.trim().length;
    return length > 0 ? length : 1;
  }

  /// Get final highlight length after a dictionary search.
  int getFinalHighlightLength({
    required DictionarySearchResult? result,
    required String searchTerm,
  }) {
    if (isSpaceDelimited) {
      RegExp regex = RegExp('[ ]');

      int numberOfWords =
          result?.entries.firstOrNull?.word.splitWithDelim(regex).length ?? 1;
      List<String> searchTermWords = searchTerm.splitWithDelim(regex);
      return searchTermWords.sublist(0, numberOfWords).join().length;
    } else {
      return max(1, result?.bestLength ?? 0);
    }
  }

  /// Returns the starting index from which the search term should be chopped
  /// from, given a clicked index and full text. For a space-delimited language,
  /// this will return the starting index of a clicked word. Otherwise, this
  /// returns the clicked index itself.
  int getStartingIndex({
    required String text,
    required int index,
  }) {
    if (isSpaceDelimited) {
      final workingBuffer = StringBuffer();

      List<String> words = textToWords(text.replaceAll('\n', ' '));

      for (String word in words) {
        workingBuffer.write(word);
        if (workingBuffer.length > index) {
          return workingBuffer.length - word.length;
        }
      }

      return index;
    } else {
      return index;
    }
  }

  /// Some languages may want to display custom widgets rather than the built
  /// in word and reading text that is there by default. For example, Japanese
  /// may want to display a furigana widget instead.
  Widget getTermReadingOverrideWidget({
    required BuildContext context,
    required double dictionaryFontSize,
    required DictionaryEntry entry,
    required Function(String) onSearch,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          entry.word,
          style: Theme.of(context)
              .textTheme
              .titleLarge!
              .copyWith(fontWeight: FontWeight.bold),
        ),
        Text(
          entry.reading,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    );
  }

  /// Some languages may have custom widgets for generating pronunciation
  /// diagrams.
  Widget getPitchWidget({
    required double dictionaryFontSize,
    required BuildContext context,
    required String reading,
    required int downstep,
  }) {
    return const SizedBox.shrink();
  }
}

String buildLookupEntryExtra(HoshiLookupResult r, HoshiGlossaryEntry g) {
  return jsonEncode({
    'definitionTags': g.definitionTags,
    'termTags': g.termTags,
    'matched': r.matched,
    'deinflected': r.deinflected,
    'frequencies': r.term.frequencies
        .map((f) => {
              'dictName': f.dictName,
              'values': f.frequencies
                  .map((v) => {
                        'value': v.value,
                        'display': v.displayValue,
                      })
                  .toList(),
            })
        .toList(),
    'pitches': r.term.pitches
        .map((p) => {
              'dictName': p.dictName,
              'positions': p.pitchPositions,
              'transcriptions': p.transcriptions,
            })
        .toList(),
  });
}

const int defaultDictionaryLookupScanLength = 16;

DictionarySearchResult buildResultFromLookup({
  required String searchTerm,
  required List<HoshiLookupResult> results,
  required int maximumTerms,
}) {
  int bestLength = 0;
  final entries = <DictionaryEntry>[];
  outer:
  for (final r in results) {
    if (r.matched.length > bestLength) {
      bestLength = r.matched.length;
    }
    for (final g in r.term.glossaries) {
      if (entries.length >= maximumTerms) break outer;
      entries.add(DictionaryEntry(
        dictionaryName: g.dictName,
        word: r.term.expression,
        reading: r.term.reading,
        meaning: g.glossary,
        extra: buildLookupEntryExtra(r, g),
      ));
    }
  }
  return DictionarySearchResult(
    searchTerm: searchTerm,
    entries: entries,
    bestLength: bestLength,
  );
}

String buildPopupJsonFromLookup({
  required List<HoshiLookupResult> results,
  required int maximumTerms,
}) {
  if (results.isEmpty) return '[]';

  final groupKeys = <String>[];
  final groupExpression = <String, String>{};
  final groupReading = <String, String>{};
  final groupMatched = <String, String>{};
  final groupDeinflected = <String, String>{};
  final groupFrequencies = <String, List<HoshiFrequencyEntry>>{};
  final groupPitches = <String, List<HoshiPitchEntry>>{};
  final seenFreqs = <String, Set<String>>{};
  final seenPitches = <String, Set<String>>{};
  final groupGlossaries = <String,
      List<
          ({
            String dictionary,
            String contentJson,
            String defTags,
            String termTags,
          })>>{};

  int entryCount = 0;
  outer:
  for (final r in results) {
    for (final g in r.term.glossaries) {
      if (entryCount >= maximumTerms) break outer;
      entryCount++;

      final key = '${r.term.expression}\n${r.term.reading}';
      if (!groupExpression.containsKey(key)) {
        groupKeys.add(key);
        groupExpression[key] = r.term.expression;
        groupReading[key] = r.term.reading;
        groupMatched[key] = r.matched;
        groupDeinflected[key] = r.deinflected;
        groupFrequencies[key] = [];
        groupPitches[key] = [];
        seenFreqs[key] = {};
        seenPitches[key] = {};
        groupGlossaries[key] = [];
      } else if (groupMatched[key] == groupExpression[key] &&
          r.matched != r.term.expression) {
        // Unlike the fallback path (buildLookupEntriesJson), the last
        // qualifying deinflection wins here. This is intentional: matched
        // and trace stay consistent on the same HoshiLookupResult.
        groupMatched[key] = r.matched;
        groupDeinflected[key] = r.deinflected;
      }

      for (final f in r.term.frequencies) {
        final fKey =
            '${f.dictName}:${f.frequencies.map((v) => '${v.value}:${v.displayValue}').join(',')}';
        if (seenFreqs[key]!.add(fKey)) {
          groupFrequencies[key]!.add(f);
        }
      }
      for (final p in r.term.pitches) {
        // Fold transcriptions into the dedup key (mirrors native popup_json):
        // IPA entries have no pitch positions, so positions-only keys would
        // collapse distinct IPA records of one dict and drop all but the first.
        final pKey = '${p.dictName}:${p.pitchPositions.join(',')}'
            '|${p.transcriptions.join(',')}';
        if (seenPitches[key]!.add(pKey)) {
          groupPitches[key]!.add(p);
        }
      }

      final String m = g.glossary;
      final String contentJson =
          (m.isNotEmpty && (m[0] == '[' || m[0] == '{')) ? m : jsonEncode(m);
      groupGlossaries[key]!.add((
        dictionary: g.dictName,
        contentJson: contentJson,
        defTags: g.definitionTags,
        termTags: g.termTags,
      ));
    }
  }

  final sb = StringBuffer('[');
  for (var i = 0; i < groupKeys.length; i++) {
    if (i > 0) sb.write(',');
    final key = groupKeys[i];
    sb.write('{"expression":');
    sb.write(jsonEncode(groupExpression[key]));
    sb.write(',"reading":');
    sb.write(jsonEncode(groupReading[key]));
    sb.write(',"matched":');
    sb.write(jsonEncode(groupMatched[key]));
    sb.write(',"rules":[],"deinflectionTrace":');
    final matched = groupMatched[key]!;
    final deinflected = groupDeinflected[key]!;
    if (matched != deinflected && deinflected.isNotEmpty) {
      sb.write('[{"name":');
      sb.write(jsonEncode('$matched → $deinflected'));
      sb.write(',"description":""}]');
    } else {
      sb.write('[]');
    }
    sb.write(',"glossaries":[');
    final gl = groupGlossaries[key]!;
    for (var j = 0; j < gl.length; j++) {
      if (j > 0) sb.write(',');
      sb.write('{"dictionary":');
      sb.write(jsonEncode(gl[j].dictionary));
      sb.write(',"content":');
      sb.write(gl[j].contentJson);
      sb.write(',"definitionTags":');
      sb.write(jsonEncode(gl[j].defTags));
      sb.write(',"termTags":');
      sb.write(jsonEncode(gl[j].termTags));
      sb.write('}');
    }
    sb.write('],"frequencies":[');
    final freqs = groupFrequencies[key]!;
    for (var fi = 0; fi < freqs.length; fi++) {
      if (fi > 0) sb.write(',');
      sb.write('{"dictionary":');
      sb.write(jsonEncode(freqs[fi].dictName));
      sb.write(',"frequencies":[');
      final fvals = freqs[fi].frequencies;
      for (var k = 0; k < fvals.length; k++) {
        if (k > 0) sb.write(',');
        sb.write('{"value":');
        sb.write(fvals[k].value);
        sb.write(',"displayValue":');
        sb.write(jsonEncode(fvals[k].displayValue));
        sb.write('}');
      }
      sb.write(']}');
    }
    sb.write('],"pitches":[');
    final pitches = groupPitches[key]!;
    for (var pi = 0; pi < pitches.length; pi++) {
      if (pi > 0) sb.write(',');
      sb.write('{"dictionary":');
      sb.write(jsonEncode(pitches[pi].dictName));
      sb.write(',"pitchPositions":');
      sb.write(jsonEncode(pitches[pi].pitchPositions));
      sb.write(',"transcriptions":');
      sb.write(jsonEncode(pitches[pi].transcriptions));
      sb.write('}');
    }
    sb.write(']}');
  }
  sb.write(']');
  return sb.toString();
}

Future<DictionarySearchResult?> prepareSearchResultsStandard(
    DictionarySearchParams params) async {
  if (params.dictionaryPaths.isEmpty) return null;

  return HoshiDicts.withPaths(params.dictionaryPaths, (hoshi) {
    final results = hoshi.lookup(
      params.searchTerm,
      maxResults: params.maximumDictionarySearchResults,
    );
    if (results.isEmpty) return null;
    return buildResultFromLookup(
      searchTerm: params.searchTerm,
      results: results,
      maximumTerms: params.maximumDictionaryTermsInResult,
    );
  });
}

DictionarySearchResult? prepareSearchResultsDirectStandard({
  required String searchTerm,
  required int maximumDictionarySearchResults,
  required int maximumDictionaryTermsInResult,
}) {
  if (!HoshiDicts.isInitialized) return null;

  final swFfi = Stopwatch()..start();
  final results = HoshiDicts.instance.lookup(
    searchTerm,
    maxResults: maximumDictionarySearchResults,
  );
  swFfi.stop();
  debugPrint(
      '[dict-perf]   ffi lookup: ${swFfi.elapsedMilliseconds}ms results=${results.length}');

  if (results.isEmpty) return null;

  final swBuild = Stopwatch()..start();
  final built = buildResultFromLookup(
    searchTerm: searchTerm,
    results: results,
    maximumTerms: maximumDictionaryTermsInResult,
  );
  swBuild.stop();
  debugPrint(
      '[dict-perf]   buildResultFromLookup: ${swBuild.elapsedMilliseconds}ms entries=${built.entries.length}');

  return built;
}
