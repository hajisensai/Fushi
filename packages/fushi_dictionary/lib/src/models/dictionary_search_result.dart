import 'dart:convert';

import '../engine/fushidicts_models.dart' show FushiKanjiResult;
import 'dictionary_entry.dart';

class DictionarySearchResult {
  /// 持久化 / 线上格式：`entries` 是**逐条 [DictionaryEntry.toJson] 后的字符串**列表
  /// （双层 JSON，见 [toJson]）。
  ///
  /// BUG-5064：查词历史里出现过 `entries` 元素是 JSON 对象（单层）的行，`List<String>.from`
  /// 直接抛类型错误，整条历史读不回来。对象形式与字符串形式承载的是同一组字段，
  /// 这里两种都按同一份 [DictionaryEntry.fromMap] 还原；别的类型仍抛 [FormatException]。
  /// 读到非规范形式的调用方可以用 [hasCanonicalEntries] 判断要不要按 [toJson] 重写。
  factory DictionarySearchResult.fromJson(String json) {
    final Object? decoded = jsonDecode(json);
    if (decoded is! Map) {
      throw FormatException(
        'DictionarySearchResult JSON is not an object: '
        '${decoded.runtimeType}',
      );
    }
    return DictionarySearchResult.fromMap(Map<String, dynamic>.from(decoded));
  }

  /// [fromJson] 解出顶层 JSON 对象之后的那一步（`entries` 两种形式见 [fromJson]）。
  factory DictionarySearchResult.fromMap(Map<String, dynamic> map) {
    final List<dynamic> entriesJson = List<dynamic>.from(
      map['entries'] as List? ?? const <dynamic>[],
    );
    final kanjiJson = List<dynamic>.from(map['kanjiResults'] ?? const []);
    return DictionarySearchResult(
      searchTerm: map['searchTerm'] as String,
      bestLength: map['bestLength'] as int? ?? 0,
      truncated: map['truncated'] as bool? ?? false,
      headwordCount: map['headwordCount'] as int? ?? 0,
      scrollPosition: map['scrollPosition'] as int? ?? 0,
      entries: entriesJson.map(_entryFromJsonValue).toList(),
      kanjiResults: kanjiJson
          .map(
            (dynamic e) =>
                FushiKanjiResult.fromMap(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
    );
  }

  /// [map]（[fromJson] 的顶层对象）的 `entries` 是否是 [toJson] 写出的规范形式
  /// （缺省 / 每个元素都是字符串）。false = 能读回来，但应按 [toJson] 重写。
  static bool hasCanonicalEntries(Map<String, dynamic> map) {
    final Object? entries = map['entries'];
    return entries == null ||
        (entries is List && entries.every((Object? e) => e is String));
  }

  static DictionaryEntry _entryFromJsonValue(dynamic value) {
    if (value is String) return DictionaryEntry.fromJson(value);
    if (value is Map) {
      return DictionaryEntry.fromMap(Map<String, dynamic>.from(value));
    }
    throw FormatException(
      'DictionarySearchResult entry is neither a JSON string nor an object: '
      '${value.runtimeType}',
    );
  }

  DictionarySearchResult({
    required this.searchTerm,
    this.entries = const [],
    this.bestLength = 0,
    this.scrollPosition = 0,
    this.kanjiResults = const [],
    this.truncated = false,
    this.headwordCount = 0,
  });

  final String searchTerm;
  final List<DictionaryEntry> entries;
  final int bestLength;
  int scrollPosition;

  /// 本次结果是否因 `maximumTerms` 被截断（还有更多词头没返回）。
  ///
  /// BUG-1472：以前消费方靠 `entries.length < maximumTerms` **反推**有没有被截断。
  /// 那个反推在预算单位 = glossary 注释行时勉强成立，改成按词头计预算后就彻底错位
  /// （一个词头能带 N 条 entries，两个数字不再可比）。截断是构造结果的人才知道的
  /// 事实，让它显式带出来，消费方不再猜。
  final bool truncated;

  /// 本次结果里 distinct 词头（表记 + 有效读音）的个数。
  ///
  /// BUG-1478：「加载更多」要按**词头**递增上限（`headwordCount + maximumTerms`）。
  /// 以前拿 `entries.length` 当基数，而那是 glossary 注释行数——同一个数字被两层
  /// 当两种语义用的老毛病（[[BUG-1472]]）在分页这一处的残留：一个词头带十几条注释
  /// 时上限会一次暴涨十几倍，等于每次下滚都把整本词典往回捞。
  final int headwordCount;

  /// Per-character kanji dictionary results for a single-character lookup
  /// (onyomi / kunyomi / radical / strokes / meanings). Empty for multi-char
  /// terms or when no kanji dictionary is loaded. S4 populates this so the S5
  /// popup can render the kanji card; it does NOT replace [entries] (a single
  /// kanji can be both a term headword and a kanji entry).
  final List<FushiKanjiResult> kanjiResults;

  String? popupJson;

  /// 结果由已配对电脑查出时，那台电脑的词典自带样式（词典名 → CSS）；null = 本机
  /// 结果，弹窗用本机 `FushiDicts.dictionaryStyles`。
  ///
  /// BUG-3612：瘦客户端（iPad 一部词典都没装）看电脑媒体库视频时，查词经
  /// `AppModel` 的 remote-first 路径由电脑完成，但弹窗在本机渲染、Glossary 也在本机
  /// 导出（`popup.js` 读 `window.dictionaryStyles`）——样式必须随结果一起带回来，
  /// 不能用本机那份空表。不进 [toJson]：只活在本次渲染里，不进缓存与同步。
  Map<String, String>? remoteDictionaryStyles;

  /// Returns a copy carrying [kanji] in [kanjiResults] while preserving the
  /// term [entries], [popupJson], [bestLength] and [scrollPosition]. Used by the
  /// search path to attach a single-kanji lookup's kanji-dictionary results to a
  /// freshly built term result without mutating the (final) term fields.
  DictionarySearchResult withKanjiResults(List<FushiKanjiResult> kanji) {
    final DictionarySearchResult copy = DictionarySearchResult(
      searchTerm: searchTerm,
      entries: entries,
      bestLength: bestLength,
      scrollPosition: scrollPosition,
      kanjiResults: kanji,
      truncated: truncated,
      headwordCount: headwordCount,
    );
    copy.popupJson = popupJson;
    copy.remoteDictionaryStyles = remoteDictionaryStyles;
    return copy;
  }

  String toJson() {
    return jsonEncode({
      'searchTerm': searchTerm,
      'bestLength': bestLength,
      'truncated': truncated,
      'headwordCount': headwordCount,
      'scrollPosition': scrollPosition,
      'entries': entries.map((e) => e.toJson()).toList(),
      'kanjiResults': kanjiResults.map((k) => k.toMap()).toList(),
    });
  }
}
