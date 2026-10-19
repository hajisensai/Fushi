/// 字幕行内标签剥离共享实现（G11 收敛：此前 srt / vtt / lrc 三个解析器各持一份
/// 逐字相同的正则替换）。

/// 注音（振假名）标注元素：`<rt>` 是读音本身，`<rp>` 是给不支持 ruby 的渲染器看的
/// 回退括号，`<rtc>` 是读音容器。三者的**内容都不是正文**——只有 ruby base 是。
/// 光删标签保留内容会把读音拼进正文（`<ruby>震<rt>ふる</rt></ruby>` → `震ふる`），
/// 污染查词 / 制卡 sentence / 字数统计，故整段丢弃（BUG-1161）。
///
/// 元素集合与 EPUB 侧 `EpubBook._removeRubyAnnotations`（`querySelectorAll('rt, rp, rtc')`
/// 逐个 remove）相同：`rt` / `rp` / `rtc` 三者内容都丢、只留 ruby base。阅读器 JS 的
/// `isFurigana()` 只 `closest('rt, rp')`、**不含 `rtc`**（既有差异，见 BUG-711）；合法 HTML 里
/// `<rtc>` 总包着 `<rt>`，实际结果收敛，但别把这里说成「与 JS 一致」。
///
/// **这是正则近似，不是 DOM 解析。** EPUB 侧走 `package:html` 真解析器，实体、嵌套、畸形标签
/// 由解析器兜底；字幕侧只有一行纯文本，没有解析器可用。两侧因此只在**良构输入**上等价，
/// 在**畸形输入**上可能分岔。本实现的取向是：认不出的形态整体不匹配、退回下面的通用模式
/// （= 旧行为），宁可多留一个假名，也绝不吃掉用户真正要读的正文。
///
/// 一条规则同时吃下两种闭合形态，不为「缺 `</rt>`」单开分支：
/// - 显式闭合 `<rt>ふる</rt>`（WebVTT 要求闭合）；
/// - 隐式闭合 `<ruby>震<rt>ふる</ruby>`（HTML 允许省略 `</rt>`，由 `</ruby>` 收尾）。
///
/// 做法是把注音内容定义成「开标签之后、下一个 ruby 家族标签之前的所有字符」，可选地
/// 连同自己的闭合标签一起吃掉。剩下的 `<ruby>` / `</ruby>` / `<rb>` 外壳标签由下面的
/// 通用模式删掉、内容（= ruby base）保留。
///
/// 开标签的属性段写成 `(?:[^<>/]|/(?!>))*` 而不是 `[^>]*`，这是兑现上面那句承诺的关键：
/// - **不许跨越 `<`**：`<ruby>漢<rt かん</ruby>の話`（缺 `>`）不能借 `</ruby>` 的 `>` 把开标签凑
///   「合法」，否则内容组会把后面的正文「の話」一路吃光。整体不匹配 → 退回旧行为 `漢の話`。
/// - **不许把自闭合当成有内容的开标签**：`a<rt/>b`（TTML / XHTML 派生字幕里真实存在）同理
///   → 退回旧行为 `ab`，而不是把 `b` 吞掉。
///
/// 实现在 Rust（`ffc_parse_subtitle_strip_html_tags`，
/// native/fushi_compute/src/parse/subtitle/markup.rs 的 `strip_html_tags`，逐条复刻原先的两条
/// 正则：注音元素 `<(?:rt|rp|rtc)\b(?:[^<>/]|/(?!>))*>(?:(?!</?(?:ruby|rt|rp|rtc)\b).)*`
/// `(?:</(?:rt|rp|rtc)\s*>)?`（忽略大小写、dotAll）与通用 `<[^>]+>`）。
///
/// 下面 [stripHtmlTags] 的取向说明仍然成立。
library;

import 'package:fushi_compute/fushi_compute.dart';

/// 剥离字幕文本中的 `<...>` 行内标签：仅移除标签本身、保留标签内文本，
/// 并去除首尾空白。例如 `<i>こんにちは</i>` → `こんにちは`。
///
/// 例外是注音标注（`<rt>` / `<rp>` / `<rtc>`）：内容随标签一起丢弃，只留 ruby base
/// （`<ruby>震<rt>ふる</rt></ruby>` → `震`）。增强 LRC 词级时间标签（`<MM:SS.xx>`）与
/// HTML 标签同形，一并剥离。
///
/// 注意：fushi_anki 的 `BaseAnkiRepository.previewFromFieldValue` 有一份
/// **故意不同**的实现——那边把标签替换成**空格**再统一折叠（Anki 字段 HTML 里
/// `<br>` / 块级标签承担换行分词，直接删空会把相邻词粘连）；而字幕行内标签
/// 紧贴正文，替换成空格反而会在日文句中引入假空格。两份实现不强并。
///
/// 没有 `<` 的行（逐行调用里的绝大多数，如 LRC 去掉时间标签后的正文）两条规则都不可能
/// 命中，结果就是 `trim()`：直接返回，不为它跨一次 FFI（每行 ~1 µs 的固定开销比旧正则
/// 的不命中路径还贵）。
String stripHtmlTags(String text) => text.contains('<')
    ? SubtitleParseNative.instance.stripHtmlTags(text)
    : text.trim();

/// 批量 [stripHtmlTags]：第 i 项逐字等于 `stripHtmlTags(texts[i])`。含 `<` 的项整批一次 FFI
/// （`SubtitleParseNative.stripHtmlTagsBatch`，循环在 Rust），其余项与单条入口一样只
/// `trim()`。逐行解析的格式（增强 LRC 每行都带 `<MM:SS.xx>`）先攒齐整份再调这里，不要在
/// 行循环里逐行调 [stripHtmlTags]。
List<String> stripHtmlTagsBatch(List<String> texts) {
  final List<String> out = List<String>.filled(texts.length, '');
  final List<int> tagged = <int>[];
  final List<String> taggedTexts = <String>[];
  for (int i = 0; i < texts.length; i++) {
    final String text = texts[i];
    if (text.contains('<')) {
      tagged.add(i);
      taggedTexts.add(text);
    } else {
      out[i] = text.trim();
    }
  }
  if (tagged.isNotEmpty) {
    final List<String> stripped = SubtitleParseNative.instance
        .stripHtmlTagsBatch(taggedTexts);
    for (int k = 0; k < tagged.length; k++) {
      out[tagged[k]] = stripped[k];
    }
  }
  return out;
}
