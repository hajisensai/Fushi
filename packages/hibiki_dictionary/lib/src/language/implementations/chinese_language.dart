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

  static int _lookupMatchedLength(String text) {
    if (!HoshiDicts.isInitialized) return 0;
    final results = HoshiDicts.instance.lookup(text, maxResults: 1);
    if (results.isEmpty) return 0;
    return results.first.matched.length;
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
