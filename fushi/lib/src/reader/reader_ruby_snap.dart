import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;

/// 查 [term]（带原文振假名 [rubySpans]）后正文里命中的长度（`lookupHighlightCharCount`
/// 口径，即 `bestLength` 的 UTF-16 长度；0 = 没查到）。与 [RubySnapTap.tapIndex] 同单位。
typedef RubySnapMatchedLength =
    Future<int> Function(String term, List<FushiRubySpan> rubySpans);

/// 让正文 WebView 把选区换成从被点字起扫的那份（`adoptRubySnapTap`），返回是否换成。
typedef RubySnapAdoptTapStart = Future<bool> Function(String expectedText);

/// ssJjbvbAbs：点中 `<ruby>` 基字时 JS 把查词起点吸附到 ruby 组首（chj2rZn89F：近衛 点「衛」
/// 查「近衛」）。但义训会把两个词标进同一个 ruby（`<ruby>じょうろ鼬<rt>ポットウィーゼル</rt></ruby>`），
/// 从组首只查到「じょうろ」，点「鼬」永远查不到鼬。吸附只能是「先从组首试」：组首查到的词
/// 覆盖到被点的字才采用，覆盖不到就改用从被点字起扫的候选 [ReaderSelectionData.rubySnapTap]。
///
/// 没有候选（没吸附 / 点的就是组首）原样返回 [data]。采用候选时先让 JS 换选区
/// （[adoptTapStart]），换不成（选区已被新点击换掉）也原样返回，高亮与查词仍对得上同一份选区。
Future<ReaderSelectionData> resolveRubySnapSelection(
  ReaderSelectionData data, {
  required RubySnapMatchedLength matchedLength,
  required RubySnapAdoptTapStart adoptTapStart,
}) async {
  final RubySnapTap? snap = data.rubySnapTap;
  if (snap == null) return data;
  final int matched = await matchedLength(data.text, data.rubySpans);
  if (matched > snap.tapIndex) return data;
  if (!await adoptTapStart(data.text)) return data;
  return snap.selection;
}
