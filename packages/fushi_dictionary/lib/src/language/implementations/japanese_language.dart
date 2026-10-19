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

  /// 文本开头的最长匹配长度（UTF-16 码元；0 = 未命中 / 引擎未就绪）。
  ///
  /// 原生 `fushidicts_match_length`，与 [textToWords] 共用句柄内的匹配长度缓存（键是
  /// 引擎真正读到的扫描窗口，词典集合一变缓存随句柄重建；以前 Dart 侧的静态 LRU 从不
  /// 失效，换词典后还在吐旧长度）。
  static int _lookupMatchedLength(String text) {
    if (!FushiDicts.isInitialized) return 0;
    return FushiDicts.instance.matchedLength(text);
  }

  @override
  Future<void> prepareResources() async {}

  /// 最长匹配分词：一次原生调用（`fushidicts_tokenize`）切完整段。
  ///
  /// 切分规则（原生 tokenize.hpp，与此前 Dart 逐位置循环逐位一致）：每个位置取引擎
  /// 首条结果的 matched 长度，未命中切一个 **UTF-16 码元**——未命中的增补平面字因此
  /// 被劈成两个半码元碎片（subtitle_word_sweep / texthooker 依赖这一点，BUG-3086）。
  /// 各段按序拼回即原文。
  @override
  List<String> textToWords(String text) {
    if (!FushiDicts.isInitialized || text.isEmpty) {
      return text.split('').where((c) => c.isNotEmpty).toList();
    }
    final List<int>? lengths = FushiDicts.instance.tokenizeLengths(text);
    if (lengths == null) return text.split('');
    return _slice(text, lengths);
  }

  /// [textToWords] 的同一次切分，外加每段的读音（每段 `lookup(段, 1)` 的首条读音，
  /// 未命中为空串），批量、在后台 isolate 里跑——浏览器扩展 yomitan `tokenize` 端点用
  /// （整页分词实测约 177 ms，同步做会把 UI isolate 卡住一整帧以上）。
  ///
  /// 返回与 [texts] 等长、按序对应的结果。引擎未就绪、实例已退役、某段原生失败时，
  /// 该段退化成逐码元、读音为空（与此前同步版同一套降级）。
  Future<List<List<({String text, String reading})>>>
  textsToWordsWithReadingsInBackground(List<String> texts) async {
    if (!FushiDicts.isInitialized || texts.every((String t) => t.isEmpty)) {
      return <List<({String text, String reading})>>[
        for (final String t in texts) _unsegmented(t),
      ];
    }
    final List<({List<int> lengths, List<String> readings})?>? results =
        await FushiDicts.instance.tokenizeWithReadingsInBackground(texts);
    return <List<({String text, String reading})>>[
      for (int i = 0; i < texts.length; i++)
        _withReadings(texts[i], results?[i]),
    ];
  }

  static List<({String text, String reading})> _withReadings(
    String text,
    ({List<int> lengths, List<String> readings})? r,
  ) {
    if (text.isEmpty || r == null) return _unsegmented(text);
    final List<String> words = _slice(text, r.lengths);
    return <({String text, String reading})>[
      for (int i = 0; i < words.length; i++)
        (text: words[i], reading: r.readings[i]),
    ];
  }

  static List<({String text, String reading})> _unsegmented(String text) =>
      <({String text, String reading})>[
        for (final String c in text.split('')) (text: c, reading: ''),
      ];

  static List<String> _slice(String text, List<int> lengths) {
    final List<String> words = <String>[];
    int pos = 0;
    for (final int length in lengths) {
      words.add(text.substring(pos, pos + length));
      pos += length;
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
