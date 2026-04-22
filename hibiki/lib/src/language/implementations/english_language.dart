import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:lemmatizerx/lemmatizerx.dart';
import 'package:isar/isar.dart';
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
Future<DictionarySearchResult?> prepareSearchResultsEnglishLanguage(
    DictionarySearchParams params) async {
  final Lemmatizer lemmatizer = Lemmatizer();
  final Isar database = await Isar.open(
    globalSchemas,
    directory: params.directoryPath,
    maxSizeMiB: 8192,
  );

  int bestLength = 0;
  String searchTerm = params.searchTerm.toLowerCase().trim();

  /// Handles contractions well enough.
  searchTerm = searchTerm
      .replaceAll('won\'t', 'will not')
      .replaceAll('can\'t', 'cannot')
      .replaceAll('i\'m', 'i am')
      .replaceAll('ain\'t', 'is not')
      .replaceAll('\'ll', ' will')
      .replaceAll('n\'t', ' not')
      .replaceAll('\'ve', ' have')
      .replaceAll('\'s', ' is')
      .replaceAll('\'re', ' are')
      .replaceAll('\'d', ' would')
      .replaceAll('’t', ' not')
      .replaceAll('’ll', ' will')
      .replaceAll('’ve', ' have')
      .replaceAll('’s', ' is')
      .replaceAll('’re', ' are')
      .replaceAll('’d', ' would');

  if (searchTerm.isEmpty) {
    return null;
  }

  int maximumEntries = params.maximumDictionarySearchResults;

  Map<int, DictionaryEntry> uniqueEntriesById = {};

  int limit() {
    return maximumEntries - uniqueEntriesById.length;
  }

  bool shouldSearchWildcards = params.searchWithWildcards &&
      (searchTerm.contains('*') || searchTerm.contains('?'));

  if (shouldSearchWildcards) {
    bool noExactMatches = database.dictionaryEntrys
        .where()
        .wordEqualTo(searchTerm)
        .isEmptySync();

    if (noExactMatches) {
      String matchesTerm = searchTerm;

      List<DictionaryEntry> termMatchEntries = [];

      bool questionMarkOnly = !matchesTerm.contains('*');
      String noAsterisks = searchTerm
          .replaceAll('※', '*')
          .replaceAll('？', '?')
          .replaceAll('*', '');

      if (params.maximumDictionaryTermsInResult > uniqueEntriesById.length) {
        if (questionMarkOnly) {
          termMatchEntries = database.dictionaryEntrys
              .where()
              .wordLengthEqualTo(searchTerm.length)
              .filter()
              .wordMatches(matchesTerm, caseSensitive: false)
              .limit(maximumEntries - uniqueEntriesById.length)
              .findAllSync();
        } else {
          termMatchEntries = database.dictionaryEntrys
              .where()
              .wordLengthGreaterThan(noAsterisks.length, include: true)
              .filter()
              .wordMatches(matchesTerm, caseSensitive: false)
              .limit(maximumEntries - uniqueEntriesById.length)
              .findAllSync();
        }
      }

      uniqueEntriesById.addEntries(
        termMatchEntries.map(
          (entry) => MapEntry(entry.id!, entry),
        ),
      );
    }
  } else {
    Map<int, List<DictionaryEntry>> termExactResultsByLength = {};
    Map<int, List<DictionaryEntry>> termDeinflectedResultsByLength = {};
    Map<int, List<DictionaryEntry>> termStartsWithResultsByLength = {};

    List<String> segments = searchTerm.splitWithDelim(RegExp('[ -\']'));

    if (segments.length > 20) {
      segments = segments.sublist(0, 10);
    }
    if (segments.length >= 3) {
      String firstWord = segments.removeAt(0);
      String secondWord = segments.removeAt(0);
      String thirdWord = segments.removeAt(0);
      segments = [
        if (firstWord.length > 3)
          if (firstWord.split('').length > 3) ...[
            firstWord.substring(0, firstWord.length - 3),
            firstWord[firstWord.length - 3],
            firstWord[firstWord.length - 2],
            firstWord[firstWord.length - 1],
          ] else
            ...firstWord.split('')
        else
          firstWord,
        if (secondWord.length > 3)
          if (secondWord.split('').length > 3) ...[
            secondWord.substring(0, secondWord.length - 3),
            secondWord[secondWord.length - 3],
            secondWord[secondWord.length - 2],
            secondWord[secondWord.length - 1],
          ] else
            ...secondWord.split('')
        else
          secondWord,
        if (thirdWord.length > 3)
          if (thirdWord.split('').length > 3) ...[
            thirdWord.substring(0, thirdWord.length - 3),
            thirdWord[thirdWord.length - 3],
            thirdWord[thirdWord.length - 2],
            thirdWord[thirdWord.length - 1],
          ] else
            ...thirdWord.split('')
        else
          thirdWord,
      ];
    } else {
      String firstWord = segments.removeAt(0);
      segments = [
        if (firstWord.length >= 3) ...firstWord.split('') else firstWord,
      ];
    }

    for (int i = 0; i < segments.length; i++) {
      String partialTerm = segments
          .sublist(0, segments.length - i)
          .join()
          .replaceAll(RegExp('[^a-zA-Z -]'), '');

      if (partialTerm.endsWith(' ')) {
        continue;
      }

      List<String> blocks = partialTerm.split(' ');
      String lastBlock = blocks.removeLast();

      List<String> possibleDeinflections = lemmatizer
          .lemmas(lastBlock)
          .map((lemma) => lemma.lemmas)
          .flattened
          .where((e) => e.isNotEmpty)
          .map(
            (e) => [...blocks, e].join(),
          )
          .toList();

      List<DictionaryEntry> termExactResults = [];
      List<DictionaryEntry> termDeinflectedResults = [];
      List<DictionaryEntry> termStartsWithResults = [];

      termExactResults = database.dictionaryEntrys
          .where(sort: Sort.desc)
          .wordEqualTo(partialTerm)
          .limit(limit())
          .findAllSync();

      if (possibleDeinflections.isNotEmpty) {
        termDeinflectedResults = database.dictionaryEntrys
            .where()
            .anyOf<String, String>(
                possibleDeinflections, (q, term) => q.wordEqualTo(term))
            .limit(limit())
            .findAllSync();
      }

      if (partialTerm.length >= 3) {
        termStartsWithResults = database.dictionaryEntrys
            .where()
            .wordStartsWith(partialTerm)
            .sortByWordLength()
            .limit(limit())
            .findAllSync();
      }

      if (termExactResults.isNotEmpty) {
        termExactResultsByLength[partialTerm.length] = termExactResults;
        bestLength = partialTerm.length;
      }
      if (termDeinflectedResults.isNotEmpty) {
        termDeinflectedResultsByLength[partialTerm.length] =
            termDeinflectedResults;
        bestLength = partialTerm.length;
      }
      if (termStartsWithResults.isNotEmpty) {
        termStartsWithResultsByLength[partialTerm.length] =
            termStartsWithResults;
        bestLength = partialTerm.length;
      }
    }

    for (int length = searchTerm.length; length > 0; length--) {
      List<MapEntry<int, DictionaryEntry>> exactEntriesToAdd = [
        ...(termExactResultsByLength[length] ?? [])
            .where((e) => e.id != null)
            .map((entry) => MapEntry(entry.id!, entry)),
      ];

      List<MapEntry<int, DictionaryEntry>> deinflectedEntriesToAdd = [
        ...(termDeinflectedResultsByLength[length] ?? [])
            .where((e) => e.id != null)
            .map((entry) => MapEntry(entry.id!, entry)),
      ];

      uniqueEntriesById.addEntries(exactEntriesToAdd);
      uniqueEntriesById.addEntries(deinflectedEntriesToAdd);

      if (params.searchWithWildcards) {
        for (int length = searchTerm.length; length > 0; length--) {
          List<MapEntry<int, DictionaryEntry>> startsWithEntriesToAdd = [
            ...(termStartsWithResultsByLength[length] ?? [])
                .where((e) => e.id != null)
                .map((entry) => MapEntry(entry.id!, entry)),
          ];

          uniqueEntriesById.addEntries(startsWithEntriesToAdd);
        }
      }
    }

    if (!params.searchWithWildcards) {
      for (int length = searchTerm.length; length > 0; length--) {
        List<MapEntry<int, DictionaryEntry>> startsWithEntriesToAdd = [
          ...(termStartsWithResultsByLength[length] ?? [])
              .where((e) => e.id != null)
              .map((entry) => MapEntry(entry.id!, entry)),
        ];

        uniqueEntriesById.addEntries(startsWithEntriesToAdd);
      }
    }
  }

  List<DictionaryEntry> entries = uniqueEntriesById.values.toList();

  if (entries.isEmpty) {
    return null;
  }

  entries = entries.sublist(
      0, min(entries.length, params.maximumDictionaryTermsInResult));

  return DictionarySearchResult(
    searchTerm: searchTerm,
    entries: entries,
    bestLength: bestLength,
  );
}
