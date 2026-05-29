import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../../engine/hoshidicts.dart';
import '../../formats/yomichan_dictionary_format.dart';
import '../language.dart';

class ChineseLanguage extends Language {
  ChineseLanguage._privateConstructor()
      : super(
          languageName: '中文',
          languageCode: 'zh',
          countryCode: 'CN',
          threeLetterCode: 'zho',
          preferVerticalReading: false,
          textDirection: TextDirection.ltr,
          isSpaceDelimited: false,
          textBaseline: TextBaseline.ideographic,
          helloWorld: '你好世界',
          prepareSearchResults: prepareSearchResultsStandard,
          standardFormat: YomichanFormat.instance,
          defaultFontFamily: 'NotoSansSC',
        );

  static ChineseLanguage get instance => _instance;

  static final ChineseLanguage _instance =
      ChineseLanguage._privateConstructor();

  // HBK-AUDIT-099: mirror JapaneseLanguage's match-length cache so Chinese
  // segmentation does not re-run the synchronous native FFI lookup for every
  // repeated prefix (e.g. textToWords + wordFromIndex/getWordRange hitting the
  // same text). Keyed on the first 20 chars with LRU eviction at 5000 entries,
  // identical to japanese_language.dart to keep the two paths from drifting.
  static const int _maxMatchCache = 5000;
  static final LinkedHashMap<String, int> _matchLengthCache =
      LinkedHashMap<String, int>();

  static int _lookupMatchedLength(String text) {
    if (!HoshiDicts.isInitialized) return 0;
    final String key = text.length > 20 ? text.substring(0, 20) : text;
    final int? cached = _matchLengthCache.remove(key);
    if (cached != null) {
      _matchLengthCache[key] = cached;
      return cached;
    }
    final results = HoshiDicts.instance.lookup(text, maxResults: 1);
    final int len = results.isEmpty ? 0 : results.first.matched.length;
    _matchLengthCache[key] = len;
    while (_matchLengthCache.length > _maxMatchCache) {
      _matchLengthCache.remove(_matchLengthCache.keys.first);
    }
    return len;
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
    required HibikiTextSelection selection,
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
}
