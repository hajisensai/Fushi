import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/language.dart';
import 'package:hibiki/models.dart';

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

/// Top-level function for use in compute. See [Language] for details.
///
/// Previously used Isar for dictionary search; will be replaced by
/// hoshidicts (C++ FFI).
Future<DictionarySearchResult?> prepareSearchResultsEnglishLanguage(
    DictionarySearchParams params) async {
  throw UnimplementedError('Will be replaced by hoshidicts');
}
