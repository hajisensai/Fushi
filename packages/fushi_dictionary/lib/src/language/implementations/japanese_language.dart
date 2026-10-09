import 'dart:async';
import 'dart:collection';

import 'package:material_ui/material_ui.dart';
import 'package:kana_kit/kana_kit.dart';
import 'package:fushi_dictionary/src/language/ruby_text.dart';

import '../../engine/fushidicts.dart';
import '../../formats/yomichan_dictionary_format.dart';
import '../../models/dictionary_entry.dart';
import '../language_base.dart';
import '../language_utils.dart';
import '../../models/fushi_text_selection.dart';

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
  static const int _maxSegmentsCacheSize = 500;
  final LinkedHashMap<DictionaryEntry, List<RubyTextData>?> segmentsCache =
      LinkedHashMap<DictionaryEntry, List<RubyTextData>?>();

  static const int _maxMatchCache = 5000;
  static final LinkedHashMap<String, int> _matchLengthCache =
      LinkedHashMap<String, int>();

  /// 匹配长度缓存的键：引擎只看查询串的前 [FushiDicts.defaultScanLength] 个
  /// **码点**——候选前缀都在这个扫描窗口内，BUG-3088 的关西方言保护结构判定也只
  /// 读窗口内的文本——所以键取的正是这段，结果只依赖键里的文本。
  ///
  /// 旧键是前 20 个 UTF-16 单元：全 BMP 文本时恰好盖住 16 个码点，但窗口里每多
  /// 一个增补平面字（𠮷 这类，占两个单元）就少盖一个码点，两段只在键外不同的
  /// 文本会共享同一个缓存值。按码点截断后两者对齐。
  @visibleForTesting
  static String matchLengthCacheKey(String text) {
    int units = 0;
    int codePoints = 0;
    while (units < text.length && codePoints < FushiDicts.defaultScanLength) {
      final int unit = text.codeUnitAt(units);
      final bool surrogatePair =
          unit >= 0xD800 &&
          unit <= 0xDBFF &&
          units + 1 < text.length &&
          (text.codeUnitAt(units + 1) & 0xFC00) == 0xDC00;
      units += surrogatePair ? 2 : 1;
      codePoints++;
    }
    return units == text.length ? text : text.substring(0, units);
  }

  static int _lookupMatchedLength(String text) {
    if (!FushiDicts.isInitialized) return 0;
    final String key = matchLengthCacheKey(text);
    final cached = _matchLengthCache.remove(key);
    if (cached != null) {
      _matchLengthCache[key] = cached;
      return cached;
    }
    final results = FushiDicts.instance.lookup(text, maxResults: 1);
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
    if (!FushiDicts.isInitialized || text.isEmpty) {
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
  String wordFromIndex({required String text, required int index}) {
    if (index < 0 || index >= text.length) return '';
    final sub = text.substring(index);
    final len = _lookupMatchedLength(sub);
    return len > 0 ? sub.substring(0, len) : text[index];
  }

  @override
  TextRange getWordRange({required FushiTextSelection selection}) {
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
  int getGuessHighlightLength({required String searchTerm}) {
    final len = _lookupMatchedLength(searchTerm);
    return len > 0 ? len : 1;
  }

  @override
  Widget getTermReadingOverrideWidget({
    required BuildContext context,
    required double dictionaryFontSize,
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
        style: Theme.of(
          context,
        ).textTheme.titleLarge!.copyWith(fontWeight: FontWeight.bold),
        rubyStyle: Theme.of(context).textTheme.labelSmall,
        indexAction: indexAction,
        indexStyle: indexStyle,
      );
    }

    List<RubyTextData>? segments = fetchFurigana(entry: entry);
    return RubyText(
      segments ?? [RubyTextData(entry.word, ruby: entry.reading)],
      style: Theme.of(
        context,
      ).textTheme.titleLarge!.copyWith(fontWeight: FontWeight.bold),
      rubyStyle: Theme.of(context).textTheme.labelSmall,
      indexAction: indexAction,
      indexStyle: indexStyle,
    );
  }

  List<RubyTextData>? fetchFurigana({required DictionaryEntry entry}) {
    final cached = segmentsCache.remove(entry);
    if (cached != null) {
      segmentsCache[entry] = cached;
      return cached;
    }
    List<RubyTextData> furigana = LanguageUtils.distributeFurigana(
      entry: entry,
    );

    segmentsCache[entry] = furigana;
    while (segmentsCache.length > _maxSegmentsCacheSize) {
      segmentsCache.remove(segmentsCache.keys.first);
    }

    return furigana;
  }

  @override
  Widget getPitchWidget({
    required double dictionaryFontSize,
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
          border: Border(top: BorderSide(color: color)),
        ),
        child: Text(
          text,
          style: TextStyle(color: color, fontSize: dictionaryFontSize),
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
          style: TextStyle(color: color, fontSize: dictionaryFontSize),
        ),
      );
    }

    Widget getAccentNone(String text) {
      return Container(
        padding: const EdgeInsets.only(top: 1),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Colors.transparent)),
        ),
        child: Text(
          text,
          style: TextStyle(color: color, fontSize: dictionaryFontSize),
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
        style: TextStyle(color: color, fontSize: dictionaryFontSize),
      ),
    );

    Widget widget = Wrap(
      crossAxisAlignment: WrapCrossAlignment.end,
      children: listWidgets,
    );

    return widget;
  }
}
