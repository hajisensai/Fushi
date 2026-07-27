/// 字幕行内标签剥离共享实现（G11 收敛：此前 srt / vtt / lrc 三个解析器各持一份
/// 逐字相同的正则替换）。

/// 注音（振假名）标注元素：`<rt>` 是读音本身，`<rp>` 是给不支持 ruby 的渲染器看的
/// 回退括号，`<rtc>` 是读音容器。三者的**内容都不是正文**——只有 ruby base 是。
/// 光删标签保留内容会把读音拼进正文（`<ruby>震<rt>ふる</rt></ruby>` → `震ふる`），
/// 污染查词 / 制卡 sentence / 字数统计，故整段丢弃（BUG-1146）。
///
/// 口径与 EPUB 侧 `EpubBook._removeRubyAnnotations`（`querySelectorAll('rt, rp, rtc')`
/// 逐个 remove）和 JS `isFurigana()` 一致：正文只有一个定义，三处都是「丢注音、留基准」。
///
/// 一条规则同时吃下两种闭合形态，不为「缺 `</rt>`」单开分支：
/// - 显式闭合 `<rt>ふる</rt>`（WebVTT 要求闭合）；
/// - 隐式闭合 `<ruby>震<rt>ふる</ruby>`（HTML 允许省略 `</rt>`，由 `</ruby>` 收尾）。
///
/// 做法是把注音内容定义成「开标签之后、下一个 ruby 家族标签之前的所有字符」，可选地
/// 连同自己的闭合标签一起吃掉。剩下的 `<ruby>` / `</ruby>` / `<rb>` 外壳标签由下面的
/// 通用模式删掉、内容（= ruby base）保留。
///
/// 认不出的残缺形式（如 `<rt` 缺 `>`）走通用模式退回旧行为：宁可多留一个假名，
/// 也不能吃掉用户真正要读的正文。
final RegExp _rubyAnnotationPattern = RegExp(
  r'<(?:rt|rp|rtc)\b[^>]*>(?:(?!</?(?:ruby|rt|rp|rtc)\b).)*(?:</(?:rt|rp|rtc)\s*>)?',
  caseSensitive: false,
  dotAll: true,
);

/// `<...>` 形式的行内标签：HTML/VTT（`<i>`、`<b>`、`<ruby>`、`<c.className>`）
/// 与增强 LRC 词级时间标签（`<MM:SS.xx>`）同形，统一按此模式剥离。
final RegExp _inlineTagPattern = RegExp('<[^>]+>');

/// 剥离字幕文本中的 `<...>` 行内标签：仅移除标签本身、保留标签内文本，
/// 并去除首尾空白。例如 `<i>こんにちは</i>` → `こんにちは`。
///
/// 例外是注音标注（`<rt>` / `<rp>` / `<rtc>`）：内容随标签一起丢弃，只留 ruby base
/// （`<ruby>震<rt>ふる</rt></ruby>` → `震`），见 [_rubyAnnotationPattern]。
///
/// 注意：hibiki_anki 的 `BaseAnkiRepository.previewFromFieldValue` 有一份
/// **故意不同**的实现——那边把标签替换成**空格**再统一折叠（Anki 字段 HTML 里
/// `<br>` / 块级标签承担换行分词，直接删空会把相邻词粘连）；而字幕行内标签
/// 紧贴正文，替换成空格反而会在日文句中引入假空格。两份实现不强并。
String stripHtmlTags(String text) => text
    .replaceAll(_rubyAnnotationPattern, '')
    .replaceAll(_inlineTagPattern, '')
    .trim();
