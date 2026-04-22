import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/language.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/dictionary/hoshidicts.dart';

/// Language implementation of the English language.
class EnglishLanguage extends Language {
  EnglishLanguage._privateConstructor()
      : super(
          languageName: 'English',
          languageCode: 'en',
          countryCode: 'US',
          threeLetterCode: 'eng',
          preferVerticalReading: false,
          textDirection: TextDirection.ltr,
          isSpaceDelimited: true,
          textBaseline: TextBaseline.alphabetic,
          helloWorld: 'Hello world',
          prepareSearchResults: prepareSearchResultsEnglishLanguage,
          standardFormat: MigakuFormat.instance,
          defaultFontFamily: 'Roboto',
        );

  /// Get the singleton instance of this language.
  static EnglishLanguage get instance => _instance;

  static final EnglishLanguage _instance =
      EnglishLanguage._privateConstructor();

  @override
  Future<void> prepareResources() async {}

  @override
  List<String> textToWords(String text) {
    List<String> splitText = text.splitWithDelim(RegExp(r'[-\n\r\s]+'));
    return splitText
        .mapIndexed((index, element) {
          if (index.isEven && index + 1 < splitText.length) {
            return [splitText[index], splitText[index + 1]].join();
          } else if (index + 1 == splitText.length) {
            return splitText[index];
          } else {
            return '';
          }
        })
        .where((e) => e.isNotEmpty)
        .toList();
  }
}

Future<DictionarySearchResult?> prepareSearchResultsEnglishLanguage(
    DictionarySearchParams params) async {
  if (params.dictionaryPaths.isEmpty) return null;

  final hoshi = HoshiDicts();
  try {
    for (final p in params.dictionaryPaths) {
      hoshi.addTermDict(p);
      hoshi.addFreqDict(p);
      hoshi.addPitchDict(p);
    }

    final results = hoshi.query(params.searchTerm);
    if (results.isEmpty) return null;

    final entries = <DictionaryEntry>[];
    for (final t in results) {
      for (final g in t.glossaries) {
        entries.add(DictionaryEntry(
          dictionaryName: g.dictName,
          word: t.expression,
          reading: t.reading,
          meaning: g.glossary,
          popularity: 0,
        ));
      }
    }

    return DictionarySearchResult(
      searchTerm: params.searchTerm,
      entries: entries,
      bestLength: params.searchTerm.length,
    );
  } finally {
    hoshi.dispose();
  }
}
