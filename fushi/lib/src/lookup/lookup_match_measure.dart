import 'package:characters/characters.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// [measureLookupMatchUnits] 要的查词能力：与页内查词同一查询入口与同一条目上限
/// （AppModel 实现、调用方注入）。只依赖这个窄接口，本文件与它的调用方不必为量命中
/// 长度 import AppModel（否则查词量长被拖进 import 大环）。
abstract interface class LookupMatchSearchHost {
  /// 页内查词的条目上限（偏好 `maximumTerms`）。
  int get maximumTerms;

  /// 带原文振假名的查词（[rubySpans] 为空时等价于普通查词），结果走查词缓存。
  Future<DictionarySearchResult> searchDictionaryWithRuby({
    required String searchTerm,
    required List<FushiRubySpan> rubySpans,
    bool searchWithWildcards = false,
    int? overrideMaximumTerms,
  });
}

/// Number of characters of the body text that the looked-up word actually
/// occupies, used to drive the in-text lookup highlight (`fushiSelection
/// .highlightSelection`).
///
/// BUG-206: this must be the length of the **inflected surface form as it
/// appears in the body** (the deinflection's matched source), NOT the length of
/// the dictionary headword. For 「うやうやしく」(6 chars in the body) the dictionary
/// entry's [DictionaryEntry.word] is the headword 「恭しい」(3 runes); highlighting
/// 3 chars covers only part of the word and — when the word is split across DOM
/// text nodes on Android — renders as two misaligned bands ("multi-select").
///
/// [DictionarySearchResult.bestLength] already carries the matched source length
/// (the FFI deinflection's `matched`, mirrored as Yomitan's `originalTextLength`)
/// and [Language.getFinalHighlightLength] is the canonical way to read it
/// (handling the space-delimited / non-space-delimited split). We only highlight
/// when there is at least one term entry, preserving the previous "no entries →
/// no highlight" behavior.
int lookupHighlightCharCount({
  required DictionarySearchResult result,
  required String searchTerm,
  required Language language,
}) {
  if (result.entries.isEmpty) return 0;
  return language.getFinalHighlightLength(
    result: result,
    searchTerm: searchTerm,
  );
}

/// 量 [term] 查词会命中的长度：与页内查词（`searchDictionaryResult`）同一查询——同上限
/// （[LookupMatchSearchHost.maximumTerms]）、同振假名分叉（[rubySpans] 非空走
/// [LookupMatchSearchHost.searchDictionaryWithRuby]），结果走查词缓存——但不建弹窗、不记查词历史。
/// 返回 [term] 的命中前缀长度（UTF-16 码元，与 [lookupHighlightCharCount] 同口径），查
/// 不到 = 0。
///
/// 用处：ruby 吸附判定看组首查到的词覆盖到哪（`resolveRubySnapSelection`）；手柄查词
/// 模式在查词交给副屏查词页（页内不弹窗、副屏不回报命中长度）时由本机量出命中长度
/// （[measureLookupMatchGraphemes]）。
Future<int> measureLookupMatchUnits(
  LookupMatchSearchHost host,
  String term, {
  List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
}) async {
  if (term.isEmpty) return 0;
  final DictionarySearchResult result = await host.searchDictionaryWithRuby(
    searchTerm: term,
    rubySpans: rubySpans,
    overrideMaximumTerms: host.maximumTerms,
  );
  return lookupHighlightCharCount(
    result: result,
    searchTerm: term,
    language: JapaneseLanguage.instance,
  );
}

/// 查词命中长度（[term] 的前 [matchedUnits] 个 UTF-16 码元，`searchDictionaryResult` /
/// [measureLookupMatchUnits] 的返回值）换算成字素数——手柄查词模式
/// （`ControllerLookupTarget.lookupAtCursor`）按字素算选区右端。查不到 = 0；不会把一个
/// 字素（组合字符 / emoji / 代理对）切成半个。
int lookupMatchedGraphemes(String term, int matchedUnits) {
  if (matchedUnits <= 0 || term.isEmpty) return 0;
  final int end = matchedUnits < term.length ? matchedUnits : term.length;
  return term.substring(0, end).characters.length;
}

/// 手柄查词模式四页（阅读器、视频、漫画、歌词）共用的「查词交给副屏时的命中长度」：
/// [measureLookupMatchUnits] 量出的命中前缀换算成字素数（[lookupMatchedGraphemes]）。
Future<int> measureLookupMatchGraphemes(
  LookupMatchSearchHost host,
  String term, {
  List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
}) async => lookupMatchedGraphemes(
  term,
  await measureLookupMatchUnits(host, term, rubySpans: rubySpans),
);
