import 'package:characters/characters.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/base_source_page.dart'
    show lookupHighlightCharCount;
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 量 [term] 查词会命中的长度：与页内查词（`searchDictionaryResult`）同一查询——同上限
/// （[AppModel.maximumTerms]）、同振假名分叉（[rubySpans] 非空走
/// [AppModel.searchDictionaryWithRuby]），结果走查词缓存——但不建弹窗、不记查词历史。
/// 返回 [term] 的命中前缀长度（UTF-16 码元，与 [lookupHighlightCharCount] 同口径），查
/// 不到 = 0。
///
/// 用处：ruby 吸附判定看组首查到的词覆盖到哪（`resolveRubySnapSelection`）；手柄查词
/// 模式在查词交给副屏查词页（页内不弹窗、副屏不回报命中长度）时由本机量出命中长度
/// （[measureLookupMatchGraphemes]）。
Future<int> measureLookupMatchUnits(
  AppModel appModel,
  String term, {
  List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
}) async {
  if (term.isEmpty) return 0;
  final DictionarySearchResult result = await appModel.searchDictionaryWithRuby(
    searchTerm: term,
    rubySpans: rubySpans,
    overrideMaximumTerms: appModel.maximumTerms,
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
  AppModel appModel,
  String term, {
  List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
}) async => lookupMatchedGraphemes(
  term,
  await measureLookupMatchUnits(appModel, term, rubySpans: rubySpans),
);
