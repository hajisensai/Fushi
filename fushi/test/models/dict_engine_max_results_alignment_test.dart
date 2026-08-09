import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// BUG-1307 守卫：交给 C++ 引擎的结果上限必须**等于**本次真正要消费的词头预算
/// （`effectiveMaxTerms`），不得再是硬编码常量。
///
/// 为什么这是性能根因：`native/fushidicts/fushidicts_src/lookup.cpp` 里
/// `partial_sort` + `resize(max_results)` **之后**才对存活结果逐条
/// `materialize()`（zstd 解压 glossary，每条落在 `blobs.bin` 的一个随机偏移上，
/// 冷页下 180-234us/条）。传 200 而只消费 10，等于在整条链路最贵的按需分页段上
/// 白解压 20 倍。
///
/// 本文件三组断言各守一件事：
/// 1. **输出不变性**：把结果集截到词头预算长度，`buildResultFromLookup` /
///    `buildPopupJsonFromLookup` 的输出（含 `bestLength`）逐字不变——这是「可以
///    降上限」的全部依据。
/// 2. **load-more 不被缓存击穿**：引擎原始结果缓存的键必须带上限。
/// 3. **接线守卫**：`app_model.dart` 真的把 `effectiveMaxTerms` 传给了引擎，
///    且 FFI 缓存读写走的是带上限的键。
void main() {
  FushiLookupResult makeResult({
    required String matched,
    required String expression,
    required String reading,
    required List<String> dictNames,
  }) {
    return FushiLookupResult(
      matched: matched,
      deinflected: expression,
      trace: const <FushiTransformGroup>[],
      preprocessorSteps: 0,
      term: FushiTermResult(
        expression: expression,
        reading: reading,
        rules: '',
        // 引擎侧 query_raw 的 `glossaries.push_back` 无条件执行：每个返回的 term
        // 至少带一条 glossary。fixture 必须尊重这个前提，否则守的不是真实契约。
        glossaries: <FushiGlossaryEntry>[
          for (final String d in dictNames)
            FushiGlossaryEntry(
              dictName: d,
              glossary: jsonEncode('$expression の意味（$d）'),
              definitionTags: '',
              termTags: '',
            ),
        ],
        frequencies: const <FushiFrequencyEntry>[],
        pitches: const <FushiPitchEntry>[],
      ),
    );
  }

  /// 模拟引擎按 `max_results` 排序后截断：`matched` 长者在前（partial_sort 的
  /// 首要比较键），故 fixture 本身按 matched 码点长度降序构造。
  List<FushiLookupResult> engineResults({required int count}) {
    return <FushiLookupResult>[
      for (int i = 0; i < count; i++)
        makeResult(
          // 全部是同一个查询串「図書館建設計画案」的前缀——scan_candidates 只产出
          // 前缀，这正是 bestLength 不变的依据。
          matched: '図書館建設計画案'.substring(0, 8 - (i ~/ 3).clamp(0, 7)),
          expression: '語$i',
          reading: 'ご$i',
          dictNames: <String>['辞書A', '辞書B'],
        ),
    ];
  }

  group('BUG-1307 ① 降上限后输出逐字不变', () {
    for (final int maxTerms in <int>[1, 3, 10, 25]) {
      test('maxTerms=$maxTerms：200 条 vs 截到 $maxTerms 条，entries 完全一致', () {
        final List<FushiLookupResult> full = engineResults(count: 200);
        final List<FushiLookupResult> capped = full.take(maxTerms).toList();

        final DictionarySearchResult fromFull = buildResultFromLookup(
          searchTerm: '図書館',
          results: full,
          maximumTerms: maxTerms,
        );
        final DictionarySearchResult fromCapped = buildResultFromLookup(
          searchTerm: '図書館',
          results: capped,
          maximumTerms: maxTerms,
        );

        expect(fromCapped.entries.length, fromFull.entries.length,
            reason: '条目数必须不变');
        for (int i = 0; i < fromFull.entries.length; i++) {
          expect(fromCapped.entries[i].dictionaryName,
              fromFull.entries[i].dictionaryName);
          expect(fromCapped.entries[i].word, fromFull.entries[i].word);
          expect(fromCapped.entries[i].reading, fromFull.entries[i].reading);
          expect(fromCapped.entries[i].meaning, fromFull.entries[i].meaning);
        }
        // bestLength 是用户可见的整词高亮长度（clipboard_panel_controller）。
        expect(fromCapped.bestLength, fromFull.bestLength,
            reason: 'bestLength 变了会让横幅高亮跨度变化');
      });

      test('maxTerms=$maxTerms：popupJson 逐字节一致', () {
        final List<FushiLookupResult> full = engineResults(count: 200);
        expect(
          buildPopupJsonFromLookup(
              results: full.take(maxTerms).toList(), maximumTerms: maxTerms),
          buildPopupJsonFromLookup(results: full, maximumTerms: maxTerms),
        );
      });
    }

    test('每个 term 至少一条 glossary ⇒ N 个结果必凑够 N 条词头预算', () {
      // 这是「上限可以从结果数降到词头数」的核心前提：预算先于结果数耗尽。
      //
      // BUG-1472 后断言的单位改回**词头**。fixture 每个词头带 2 本词典的注释，
      // 旧断言 `entries.length == 10` 其实是在断言 5 个词头——正是那条 bug 的本体
      // （引擎按词头发 10 条，Dart 只消费得下 5 条，另 5 条白解压且用户看不到）。
      // 现在 10 个结果 ↔ 10 条词头预算恰好对齐，BUG-1307 的前提比以前更紧。
      final DictionarySearchResult r = buildResultFromLookup(
        searchTerm: '図書館',
        results: engineResults(count: 10),
        maximumTerms: 10,
      );
      final Set<String> headwords = r.entries
          .map((DictionaryEntry e) => '${e.word}\n${e.reading}')
          .toSet();
      expect(headwords.length, 10);
      expect(r.truncated, isFalse);
    });
  });

  group('BUG-1307 ② FFI 结果缓存键必须带上限（load-more 回归守卫）', () {
    test('同词不同上限 ⇒ 不同键', () {
      expect(
        buildFfiLookupCacheKey(term: '図書館', maxResults: 10),
        isNot(buildFfiLookupCacheKey(term: '図書館', maxResults: 20)),
      );
    });

    test('键格式 len:term/maxResults，term.length 用 UTF-16 code units', () {
      expect(buildFfiLookupCacheKey(term: '図書館', maxResults: 10), '3:図書館/10');
      expect(buildFfiLookupCacheKey(term: '\u{2000B}', maxResults: 1),
          '2:\u{2000B}/1');
    });

    test('load-more 的新上限不会命中首查的短结果集', () {
      // 首查 10 → load-more 20（base_source_page.loadMoreForLayer 的 newMax）。
      final Map<String, List<FushiLookupResult>> cache =
          <String, List<FushiLookupResult>>{};
      cache[buildFfiLookupCacheKey(term: '図書館', maxResults: 10)] =
          engineResults(count: 10);
      expect(cache[buildFfiLookupCacheKey(term: '図書館', maxResults: 20)], isNull,
          reason: '若命中，load-more 拿不到新条目、allLoaded 会提前为 true');
    });
  });

  group('BUG-1307 ③ 接线守卫：app_model 真的把词头预算传给引擎', () {
    late String source;

    setUpAll(() {
      final File f = File('lib/src/models/app_model.dart');
      expect(f.existsSync(), isTrue, reason: '守卫目标文件必须存在：${f.path}');
      source = f.readAsStringSync();
    });

    test('FushiDicts.instance.lookup 的 maxResults 是 effectiveMaxTerms', () {
      final RegExp call = RegExp(
        r'FushiDicts\.instance\.lookup\(\s*searchTerm,\s*maxResults:\s*([A-Za-z0-9_]+)\s*,',
        multiLine: true,
      );
      final Iterable<RegExpMatch> ms = call.allMatches(source);
      expect(ms.length, 1, reason: '查词只应有一个引擎调用点');
      expect(ms.first.group(1), 'effectiveMaxTerms',
          reason: 'BUG-1307：上限必须等于本次消费的词头预算，不得是硬编码常量');
    });

    test('不再存在 maximumDictionarySearchResults 这个独立上限常量', () {
      expect(source.contains('maximumDictionarySearchResults'), isFalse,
          reason: '独立的 200 常量已被删除；恢复它就是恢复 20 倍白解压');
    });

    test('FFI 缓存读写都走带上限的 ffiCacheKey', () {
      expect(
          source.contains('dictRepo.getCachedFfiLookup(ffiCacheKey)'), isTrue,
          reason: '读 FFI 缓存必须用带上限的键，否则 load-more 被短结果集击穿');
      expect(source.contains('dictRepo.cacheFfiLookup(ffiCacheKey,'), isTrue,
          reason: '写 FFI 缓存必须用带上限的键');
    });
  });
}
