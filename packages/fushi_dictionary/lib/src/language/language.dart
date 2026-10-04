/// 引擎查词结果（[FushiLookupResult]）→ [DictionarySearchResult] / 弹窗 JSON 的
/// 纯逻辑（零 Flutter，无头服务端经 `fushi_dictionary_core.dart` 复用）。
/// 依赖 material 的 `Language` 抽象类在 `language_base.dart`。
library;

import 'dart:convert';
import 'dart:math';

import '../engine/fushidicts_models.dart';
import '../models/dictionary_entry.dart';
import '../models/dictionary_search_result.dart';
import 'transform_description_i18n.dart';

/// 弹窗上的一枚词形变化标签：变形名（`-て`）+ 该变形的语法说明。
typedef DeinflectionTag = ({String name, String description});

/// 词形变化链 → 弹窗标签序列。**这是全 app 唯一一处生成变形标签的地方**，
/// 三条弹窗路径（[buildPopupJsonFromLookup] / `buildLookupEntriesJson` /
/// 原生弹窗）和 C++ 的 `build_popup_json` 都必须走这套语义，不允许各自再拼。
///
/// `trace` 是唯一真相：引擎每剥掉一层变形就往里压一个 [FushiTransformGroup]，
/// 带着变形名和 `assets/transforms/<lang>.json` 里的语法说明。压栈顺序是**剥离
/// 顺序**（最外层的变形最先被剥），而用户要看的是**接续顺序**——从词典形出发依
/// 次接上了哪些变形，所以显示时整体反转：`当たっていた` 的 trace 是
/// `[-た, -いる, -て]`，显示成 `-て « -いる « -た`（与 Yomitan 一致）。
///
/// trace 为空、而 matched 又确实不等于 deinflected 时，回落成单条
/// `matched → deinflected`：那是 `lookup.cpp` 的**文本变体归一**（colour→color
/// 一类），不经过任何变形规则，所以既没有 trace 也没有语法说明。这条回落分支
/// 不能删——删了这类查询就完全不提示词形变化了。
List<DeinflectionTag> buildDeinflectionTags({
  required String matched,
  required String deinflected,
  required List<FushiTransformGroup> trace,
}) {
  if (trace.isNotEmpty) {
    return <DeinflectionTag>[
      for (final FushiTransformGroup t in trace.reversed)
        (name: t.name, description: t.description),
    ];
  }
  if (matched != deinflected && deinflected.isNotEmpty) {
    return <DeinflectionTag>[
      (name: '$matched → $deinflected', description: '')
    ];
  }
  return const <DeinflectionTag>[];
}

/// [buildDeinflectionTags] 的结果 → 弹窗 JSON 里的 `deinflectionTrace` 数组。
List<Map<String, String>> deinflectionTagsToJson(List<DeinflectionTag> tags) {
  return <Map<String, String>>[
    for (final DeinflectionTag t in tags)
      <String, String>{'name': t.name, 'description': t.description},
  ];
}

/// 变形标签的名称和语法说明 → 当前界面语言（[TransformDescriptionCatalog]）。
///
/// **只在显示边界调用**，不要下沉进 [buildDeinflectionTags]：后者同时喂着
/// [buildLookupEntryExtra] 这条**持久化**路径，那份 extra 会被缓存复用，写进译文就
/// 等于把「写入时的界面语言」腌进数据里。存英文、显示时再翻，换语言才能整体生效。
List<DeinflectionTag> localizeDeinflectionTags(List<DeinflectionTag> tags) {
  return <DeinflectionTag>[
    for (final DeinflectionTag t in tags)
      (
        name: TransformDescriptionCatalog.localize(t.name),
        description: TransformDescriptionCatalog.localize(t.description),
      ),
  ];
}

/// 从 [buildLookupEntryExtra] 写出的 extra 里读回变形标签。
///
/// extra 里存的已经是 [buildDeinflectionTags] 的成品（含回落），所以这里**只解析、
/// 不再判断**——回落语义只有一份。老 extra（没有 `deinflectionTrace` 键）才走末尾
/// 的兼容分支，靠 matched/deinflected 现算。
List<DeinflectionTag> deinflectionTagsFromExtra(Map<String, dynamic> extra) {
  final Object? raw = extra['deinflectionTrace'];
  if (raw is List) {
    // extra 里存的是英文原文（见 [localizeDeinflectionTags] 的说明），读出来给弹窗
    // 显示时才翻译。原生弹窗和 buildLookupEntriesJson 都走这里。
    return localizeDeinflectionTags(<DeinflectionTag>[
      for (final Object? item in raw)
        if (item is Map)
          (
            name: (item['name'] ?? '').toString(),
            description: (item['description'] ?? '').toString(),
          ),
    ]);
  }
  return localizeDeinflectionTags(buildDeinflectionTags(
    matched: (extra['matched'] ?? '').toString(),
    deinflected: (extra['deinflected'] ?? '').toString(),
    trace: const <FushiTransformGroup>[],
  ));
}

String buildLookupEntryExtra(FushiLookupResult r, FushiGlossaryEntry g) {
  return jsonEncode({
    'definitionTags': g.definitionTags,
    'termTags': g.termTags,
    'matched': r.matched,
    'deinflected': r.deinflected,
    // 变形链带着语法说明一起随 entry 走。走 extra 的两条弹窗路径（原生弹窗、
    // buildLookupEntriesJson）本来只能看到 matched/deinflected，只好现编一条
    // 「matched → deinflected」且说明恒空——语法说明就是断在这里的。
    'deinflectionTrace': deinflectionTagsToJson(buildDeinflectionTags(
      matched: r.matched,
      deinflected: r.deinflected,
      trace: r.trace,
    )),
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
              'patterns': p.patterns,
              'transcriptions': p.transcriptions,
            })
        .toList(),
  });
}

DictionarySearchResult buildResultFromLookup({
  required String searchTerm,
  required List<FushiLookupResult> results,
  required int maximumTerms,
  List<String> dictionaryOrder = const <String>[],
}) {
  int bestLength = 0;
  // BUG-1472：预算的单位是**词头**（表记 + 读音），不是 glossary 注释行。
  //
  // 引擎侧把 `maximumTerms` 当词头数上限用（lookup.cpp 的 max_results），这里以前却拿
  // 同一个数字去数注释行：query.cpp 会把不同词典的同一个 (expr, reading) 合并成一个
  // TermResult + N 条 glossary，于是「永遠/えいえん」这种高频词头一个人就带 7~26 行，
  // 装了几本词典就够吃满整个上限——排在它后面的 とわ / とこしえ 连循环体都进不去。
  // 用户症状：查「永遠」永远只出 えいえん。同一个数字被两层当成两种语义用，是根因。
  final Map<String, int> headwords = <String, int>{};
  // BUG-2579：词典顺序要按**词头组**排，不能按引擎结果行排。引擎只合并 (expr,
  // reading) 完全相同的行，MDX/DSL 这类 simple dict 读音恒空，与 Yomitan 的显式读音
  // 行是两条结果；这里按 [lookupHeadwordKey] 把它们归成同一个词头后，若只在各自
  // 行内排序，后一行的词典（恒是 MDX）无论管理页排第几都挂在词头尾巴上。
  final List<({DictionaryEntry entry, int headword})> collected =
      <({DictionaryEntry entry, int headword})>[];
  bool truncated = false;
  // BUG-2753：空读音的 simple dict 行并入同表记唯一的显式读音组。
  final Map<String, String> soleReadings = soleExplicitReadings(results);
  outer:
  for (final r in results) {
    if (r.matched.length > bestLength) {
      bestLength = r.matched.length;
    }
    final String headword = lookupHeadwordKey(r, soleReadings: soleReadings);
    // entry 上也写补全后的读音：buildLookupEntriesJson 按 entry.reading 再分组，
    // 制卡 / 音频 / 振假名 / Anki 查重也都读它。
    final String reading = resolvedLookupReading(r, soleReadings);
    if (!headwords.containsKey(headword) && headwords.length >= maximumTerms) {
      truncated = true;
      break outer;
    }
    final int headwordIndex =
        headwords.putIfAbsent(headword, () => headwords.length);
    for (final g in r.term.glossaries) {
      collected.add((
        entry: DictionaryEntry(
          dictionaryName: g.dictName,
          word: r.term.expression,
          reading: reading,
          meaning: g.glossary,
          extra: buildLookupEntryExtra(r, g),
        ),
        headword: headwordIndex,
      ));
    }
  }
  final List<DictionaryEntry> entries = _sortedByDictionaryOrder(
    collected,
    dictionaryOrder,
    groupOf: (item) => item.headword,
    dictNameOf: (item) => item.entry.dictionaryName,
  ).map((item) => item.entry).toList();
  return DictionarySearchResult(
    searchTerm: searchTerm,
    entries: entries,
    bestLength: bestLength,
    truncated: truncated,
    headwordCount: headwords.length,
  );
}

/// 词头分组 key：表记 + **有效**读音。
///
/// BUG-791：空读音按 Yomitan 约定等价于「读音同表记」，分组前必须归一，否则同一个
/// 假名词（reading 有的显式给、有的留空）会被拆成两个词头。只归一分组 key，不改
/// 存储的 display reading（空读音仍无注音）。
///
/// BUG-2753：[soleReadings] 来自 [soleExplicitReadings]，空读音行按它先补上该表记
/// 唯一的显式读音再分组（见 [resolvedLookupReading]）。
String lookupHeadwordKey(
  FushiLookupResult r, {
  Map<String, String> soleReadings = const <String, String>{},
}) {
  final String reading = resolvedLookupReading(r, soleReadings);
  final String effectiveReading = reading.isEmpty ? r.term.expression : reading;
  return '${r.term.expression}\n$effectiveReading';
}

/// 每个表记在本次结果里**唯一**的显式（非空）读音；有多个不同读音的表记不收。
///
/// BUG-2753：MDX / StarDict / DSL 这类 simple dict 只有「词头 → 释义」，导入时读音
/// 恒空（importer.cpp 写 reading_len = 0）。同一个 `取り戻す`，Yomitan 行是
/// `取り戻す／とりもどす`、MDX 行是 `取り戻す／（空）`，BUG-791 的归一只把空读音
/// 等同于表记本身，于是两者分组 key 不同、被拆成上下两张卡。
///
/// 只在读音**无歧义**时并入：同表记只有一个显式读音 → 空读音行就是它；同表记有
/// 多个读音（辛い＝つらい／からい）→ 不猜，空读音行保持自成一组（BUG-791 边界）。
Map<String, String> soleExplicitReadings(List<FushiLookupResult> results) {
  final Map<String, Set<String>> readings = <String, Set<String>>{};
  for (final FushiLookupResult r in results) {
    if (r.term.reading.isEmpty) continue;
    readings
        .putIfAbsent(r.term.expression, () => <String>{})
        .add(r.term.reading);
  }
  return <String, String>{
    for (final MapEntry<String, Set<String>> e in readings.entries)
      if (e.value.length == 1) e.key: e.value.single,
  };
}

/// 该行用于分组与展示的读音：显式读音原样返回；空读音补上 [soleReadings] 里该
/// 表记的唯一读音（没有则仍为空）。见 [soleExplicitReadings]。
String resolvedLookupReading(
  FushiLookupResult r,
  Map<String, String> soleReadings,
) {
  if (r.term.reading.isNotEmpty) return r.term.reading;
  return soleReadings[r.term.expression] ?? '';
}

String buildPopupJsonFromLookup({
  required List<FushiLookupResult> results,
  required int maximumTerms,
  required Set<String> hiddenDictionaries,
  List<String> dictionaryOrder = const <String>[],
}) {
  if (results.isEmpty) return '[]';

  final groupKeys = <String>[];
  final groupExpression = <String, String>{};
  final groupReading = <String, String>{};
  final groupMatched = <String, String>{};
  final groupDeinflected = <String, String>{};
  final groupTrace = <String, List<FushiTransformGroup>>{};
  final groupFrequencies = <String, List<FushiFrequencyEntry>>{};
  final groupPitches = <String, List<FushiPitchEntry>>{};
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

  // BUG-1472：与 [buildResultFromLookup] 同一处根因——预算按词头算，不按 glossary
  // 注释行算。这里本来就是按 key 分组的，所以「已有几个词头」= groupKeys.length。
  // BUG-2753：与 [buildResultFromLookup] 同一口径补全空读音。
  final Map<String, String> soleReadings = soleExplicitReadings(results);
  outer:
  for (final r in results) {
    final key = lookupHeadwordKey(r, soleReadings: soleReadings);
    if (!groupExpression.containsKey(key) && groupKeys.length >= maximumTerms) {
      break outer;
    }
    // 词典顺序在下方出 JSON 时按整张卡排（BUG-2579），这里不排：同一个词头会由
    // 多条引擎结果行拼成（显式读音的 Yomitan 行 + 空读音的 MDX 行），逐行排序只
    // 能排到行内。
    for (final g in r.term.glossaries) {
      // 被用户关掉的词典在源头就不进 popupJson。此前这步只存在于渲染期的 JS
      // （靠宿主注入 window.hiddenDictionaryNames 驱动），app 内 WebView 注入了、浏览器
      // 扩展走的 HTTP 路径从来不下发它 ⇒ 关掉的词典在扩展里照旧出释义，
      // 连制卡也一并写进去。过滤下沉到这个唯一数据出口后，app 内弹窗 / 全局查词窗 /
      // 浏览器扩展 / 制卡四个消费者一次性全对；JS 侧原有过滤退化为冗余保险。
      //
      // 放在循环最前（而不是只跳 groupGlossaries.add）：只有隐藏词典释义的词头不应
      // 该撑起一张空卡片，也不应占用 maximumTerms 词头预算。
      if (hiddenDictionaries.contains(g.dictName)) continue;
      if (!groupExpression.containsKey(key)) {
        groupKeys.add(key);
        groupExpression[key] = r.term.expression;
        // 空读音行可能先于显式读音行建组（词典顺序在 MDX 前）：取补全后的读音。
        groupReading[key] = resolvedLookupReading(r, soleReadings);
        groupMatched[key] = r.matched;
        groupDeinflected[key] = r.deinflected;
        groupTrace[key] = r.trace;
        groupFrequencies[key] = [];
        groupPitches[key] = [];
        seenFreqs[key] = {};
        seenPitches[key] = {};
        groupGlossaries[key] = [];
      } else if (groupMatched[key] == groupExpression[key] &&
          r.matched != r.term.expression) {
        // Unlike the fallback path (buildLookupEntriesJson), the last
        // qualifying deinflection wins here. This is intentional: matched
        // and trace stay consistent on the same FushiLookupResult.
        groupMatched[key] = r.matched;
        groupDeinflected[key] = r.deinflected;
        groupTrace[key] = r.trace;
      }

      for (final f in r.term.frequencies) {
        final fKey =
            '${f.dictName}:${f.frequencies.map((v) => '${v.value}:${v.displayValue}').join(',')}';
        if (seenFreqs[key]!.add(fKey)) {
          groupFrequencies[key]!.add(f);
        }
      }
      for (final p in r.term.pitches) {
        // Fold patterns + transcriptions into the dedup key (mirrors native
        // popup_json): IPA entries have no pitch accents, and pattern-only
        // accents have no numeric positions, so a positions-only key would
        // collapse distinct records of one dict and drop all but the first.
        final pKey =
            '${p.dictName}:${p.pitchPositions.join(',')},${p.patterns.join(',')}'
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
    // 弹窗 JSON 是显示路径 → 翻译；持久化的 extra 不翻（BUG-2038）。
    sb.write(jsonEncode(
        deinflectionTagsToJson(localizeDeinflectionTags(buildDeinflectionTags(
      matched: groupMatched[key]!,
      deinflected: groupDeinflected[key]!,
      trace: groupTrace[key] ?? const <FushiTransformGroup>[],
    )))));
    sb.write(',"glossaries":[');
    final gl = _sortedByDictionaryOrder(
      groupGlossaries[key]!,
      dictionaryOrder,
      groupOf: (_) => 0,
      dictNameOf: (item) => item.dictionary,
    );
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
      sb.write(',"patterns":');
      sb.write(jsonEncode(pitches[pi].patterns));
      sb.write(',"transcriptions":');
      sb.write(jsonEncode(pitches[pi].transcriptions));
      sb.write('}');
    }
    sb.write(']}');
  }
  sb.write(']');
  return sb.toString();
}

/// Applies the user-managed dictionary priority at the Dart result boundary.
///
/// The native engine normally appends glossaries in dictionary registration
/// order, but that is an implementation detail rather than part of the FFI
/// payload. A warm/independent lookup surface can therefore hand this builder
/// an older ordering even though the management page already exposes the new
/// one. Sorting here makes both [DictionarySearchResult] and popup JSON consume
/// the explicit current order. Unknown dictionaries stay last and stable.
///
/// BUG-2579：排序单位是 [groupOf] 给出的**词头组**而不是引擎结果行。[items] 里
/// 组序（首次出现顺序）保持不变，只在组内按 [dictionaryOrder] 重排；同一词典
/// 多条释义、以及不在 [dictionaryOrder] 里的词典，都保持原相对顺序（稳定）。
List<T> _sortedByDictionaryOrder<T>(
  List<T> items,
  List<String> dictionaryOrder, {
  required int Function(T item) groupOf,
  required String Function(T item) dictNameOf,
}) {
  if (items.length < 2 || dictionaryOrder.isEmpty) return items;

  final Map<String, int> rank = <String, int>{
    for (int i = 0; i < dictionaryOrder.length; i++) dictionaryOrder[i]: i,
  };
  final int unknownRank = dictionaryOrder.length;
  final Map<int, int> groupOrder = <int, int>{};
  final List<({T item, int group, int rank, int sourceIndex})> indexed =
      <({T item, int group, int rank, int sourceIndex})>[
    for (int i = 0; i < items.length; i++)
      (
        item: items[i],
        group:
            groupOrder.putIfAbsent(groupOf(items[i]), () => groupOrder.length),
        rank: rank[dictNameOf(items[i])] ?? unknownRank,
        sourceIndex: i,
      ),
  ];
  indexed.sort((a, b) {
    final int byGroup = a.group.compareTo(b.group);
    if (byGroup != 0) return byGroup;
    final int byRank = a.rank.compareTo(b.rank);
    return byRank != 0 ? byRank : a.sourceIndex.compareTo(b.sourceIndex);
  });
  return <T>[for (final item in indexed) item.item];
}

/// `Language.wordFromIndex` 的长文本截窗：以 [index] 为中心、左右各取至多
/// [maxDistance] 个字符拼出新文本，并给出原 [index] 在新文本里的位置（取不到为 -1）。
/// 原样抽自 `wordFromIndex`，让这段码点遍历留在本（零 Flutter）文件里。
({String text, int index}) windowTextAroundIndex({
  required String text,
  required int index,
  required int maxDistance,
}) {
  List<int> originalIndexTape = [];
  List<int> indexTape = [];

  int rangeStart = max(0, index - maxDistance);
  int rangeEnd = min(text.length - 1, index + maxDistance + 1);

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

  return (text: newText, index: newIndex);
}
