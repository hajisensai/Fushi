import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:kana_kit/kana_kit.dart';
import 'package:ruby_text/ruby_text.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/language.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/dictionary/hoshidicts.dart';

/// Language implementation of the Japanese language.
class JapaneseLanguage extends Language {
  JapaneseLanguage._privateConstructor()
      : super(
          languageName: '日本語',
          languageCode: 'ja',
          countryCode: 'JP',
          threeLetterCode: 'jpn',
          preferVerticalReading: true,
          textDirection: TextDirection.ltr,
          isSpaceDelimited: false,
          textBaseline: TextBaseline.ideographic,
          prepareSearchResults: prepareSearchResultsJapaneseLanguage,
          helloWorld: 'こんにちは世界',
          standardFormat: YomichanFormat.instance,
          defaultFontFamily: 'NotoSansJP',
        );

  /// Get the singleton instance of this language.
  static JapaneseLanguage get instance => _instance;

  static final JapaneseLanguage _instance =
      JapaneseLanguage._privateConstructor();

  /// Used for processing Japanese characters from Kana to Romaji and so on.
  static KanaKit kanaKit = const KanaKit();

  /// Used to cache furigana segments for already generated [DictionaryEntry]
  /// items.
  final Map<DictionaryEntry, List<RubyTextData>?> segmentsCache = {};

  static int _lookupMatchedLength(String text) {
    if (!HoshiDicts.isInitialized) return 0;
    final results =
        HoshiDicts.instance.lookup(text, maxResults: 1);
    if (results.isEmpty) return 0;
    return results.first.matched.length;
  }

  @override
  DictionarySearchResult? prepareSearchResultsDirect({
    required String searchTerm,
    required int maximumDictionarySearchResults,
    required int maximumDictionaryTermsInResult,
  }) {
    if (!HoshiDicts.isInitialized) return null;

    final results = HoshiDicts.instance.lookup(
      searchTerm,
      maxResults: maximumDictionarySearchResults,
      scanLength: maximumDictionaryTermsInResult,
    );

    if (results.isEmpty) return null;

    int bestLength = 0;
    final entries = <DictionaryEntry>[];

    for (final r in results) {
      if (r.matched.length > bestLength) {
        bestLength = r.matched.length;
      }
      for (final g in r.term.glossaries) {
        entries.add(DictionaryEntry(
          dictionaryName: g.dictName,
          word: r.term.expression,
          reading: r.term.reading,
          meaning: g.glossary,
          extra: jsonEncode({
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
                    })
                .toList(),
          }),
          popularity: 0,
        ));
      }
    }

    return DictionarySearchResult(
      searchTerm: searchTerm,
      entries: entries,
      bestLength: bestLength,
    );
  }

  @override
  Future<void> prepareResources() async {}

  @override
  List<String> textToWords(String text) {
    if (!HoshiDicts.isInitialized || text.isEmpty) {
      return text.split('').where((c) => c.isNotEmpty).toList();
    }
    final words = <String>[];
    int pos = 0;
    while (pos < text.length) {
      final sub = text.substring(pos);
      final len = _lookupMatchedLength(sub);
      if (len > 0) {
        words.add(text.substring(pos, pos + len));
        pos += len;
      } else {
        words.add(text[pos]);
        pos++;
      }
    }
    return words;
  }

  @override
  String wordFromIndex({
    required String text,
    required int index,
  }) {
    if (index < 0 || index >= text.length) return '';
    final sub = text.substring(index);
    final len = _lookupMatchedLength(sub);
    return len > 0 ? sub.substring(0, len) : text[index];
  }

  @override
  TextRange getWordRange({
    required JidoujishoTextSelection selection,
  }) {
    final index = selection.range.start;
    if (index < 0 || index >= selection.text.length) {
      return TextRange(start: index, end: index + 1);
    }
    final sub = selection.text.substring(index);
    final len = _lookupMatchedLength(sub);
    final end = len > 0 ? index + len : index + 1;
    return TextRange(start: index, end: end);
  }

  @override
  int getGuessHighlightLength({
    required String searchTerm,
  }) {
    final len = _lookupMatchedLength(searchTerm);
    return len > 0 ? len : 1;
  }

  @override
  Widget getTermReadingOverrideWidget({
    required BuildContext context,
    required AppModel appModel,
    required DictionaryEntry entry,
    required Function(String) onSearch,
  }) {
    TextStyle indexStyle(int index, String character) {
      if (kanaKit.isKanji(character)) {
        return const TextStyle(
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.dotted,
        );
      } else {
        return const TextStyle();
      }
    }

    void indexAction(int index, String character) {
      if (kanaKit.isKanji(character)) {
        onSearch(character);
      }
    }

    if (entry.reading.isEmpty) {
      return RubyText(
        [RubyTextData(entry.word)],
        style: Theme.of(context)
            .textTheme
            .titleLarge!
            .copyWith(fontWeight: FontWeight.bold),
        rubyStyle: Theme.of(context).textTheme.labelSmall,
        indexAction: indexAction,
        indexStyle: indexStyle,
      );
    }

    List<RubyTextData>? segments = fetchFurigana(entry: entry);
    return RubyText(
      segments ??
          [
            RubyTextData(entry.word, ruby: entry.reading),
          ],
      style: Theme.of(context)
          .textTheme
          .titleLarge!
          .copyWith(fontWeight: FontWeight.bold),
      rubyStyle: Theme.of(context).textTheme.labelSmall,
      indexAction: indexAction,
      indexStyle: indexStyle,
    );
  }

  List<RubyTextData>? fetchFurigana({required DictionaryEntry entry}) {
    if (segmentsCache.containsKey(entry)) {
      return segmentsCache[entry];
    }
    List<RubyTextData> furigana =
        LanguageUtils.distributeFurigana(entry: entry);

    segmentsCache[entry] = furigana;

    return furigana;
  }

  @override
  Widget getPitchWidget({
    required AppModel appModel,
    required BuildContext context,
    required String reading,
    required int downstep,
  }) {
    List<Widget> listWidgets = [];

    Color color = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;

    Widget getAccentTop(String text) {
      return Container(
        padding: const EdgeInsets.only(top: 1),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: color),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: appModel.dictionaryFontSize,
          ),
        ),
      );
    }

    Widget getAccentEnd(String text) {
      return Container(
        padding: const EdgeInsets.only(top: 1),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: color),
            right: BorderSide(color: color),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: appModel.dictionaryFontSize,
          ),
        ),
      );
    }

    Widget getAccentNone(String text) {
      return Container(
        padding: const EdgeInsets.only(top: 1),
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: Colors.transparent),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: appModel.dictionaryFontSize,
          ),
        ),
      );
    }

    List<String> moras = [];
    for (int i = 0; i < reading.length; i++) {
      String current = reading[i];
      String? next;
      if (i + 1 < reading.length) {
        next = reading[i + 1];
      }

      if (next != null && 'ゃゅょぁぃぅぇぉャュョァィゥェォ'.contains(next)) {
        moras.add(current + next);
        i += 1;
        continue;
      } else {
        moras.add(current);
      }
    }

    if (downstep == 0) {
      for (int i = 0; i < moras.length; i++) {
        if (i == 0) {
          listWidgets.add(getAccentNone(moras[i]));
        } else {
          listWidgets.add(getAccentTop(moras[i]));
        }
      }
    } else {
      for (int i = 0; i < moras.length; i++) {
        if (i == 0 && i != downstep - 1) {
          listWidgets.add(getAccentNone(moras[i]));
        } else if (i < downstep - 1) {
          listWidgets.add(getAccentTop(moras[i]));
        } else if (i == downstep - 1) {
          listWidgets.add(getAccentEnd(moras[i]));
        } else {
          listWidgets.add(getAccentNone(moras[i]));
        }
      }
    }

    listWidgets.add(
      Text(
        ' [$downstep]  ',
        style: TextStyle(
          color: color,
          fontSize: appModel.dictionaryFontSize,
        ),
      ),
    );

    Widget widget = Wrap(
      crossAxisAlignment: WrapCrossAlignment.end,
      children: listWidgets,
    );

    return widget;
  }
}

Future<DictionarySearchResult?> prepareSearchResultsJapaneseLanguage(
    DictionarySearchParams params) async {
  if (params.dictionaryPaths.isEmpty) return null;

  final hoshi = HoshiDicts.withPaths(params.dictionaryPaths);
  try {
    final results = hoshi.lookup(
      params.searchTerm,
      maxResults: params.maximumDictionarySearchResults,
      scanLength: params.maximumDictionaryTermsInResult,
    );

    if (results.isEmpty) return null;

    int bestLength = 0;
    final entries = <DictionaryEntry>[];

    for (final r in results) {
      if (r.matched.length > bestLength) {
        bestLength = r.matched.length;
      }
      for (final g in r.term.glossaries) {
        entries.add(DictionaryEntry(
          dictionaryName: g.dictName,
          word: r.term.expression,
          reading: r.term.reading,
          meaning: g.glossary,
          extra: jsonEncode({
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
                    })
                .toList(),
          }),
          popularity: 0,
        ));
      }
    }

    return DictionarySearchResult(
      searchTerm: params.searchTerm,
      entries: entries,
      bestLength: bestLength,
    );
  } finally {
    hoshi.dispose();
  }
}
