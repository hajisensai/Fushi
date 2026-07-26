/// 字幕行内标签剥离共享实现（G11 收敛：此前 srt / vtt / lrc 三个解析器各持一份
/// 逐字相同的正则替换）。

/// `<...>` 形式的行内标签：HTML/VTT（`<i>`、`<b>`、`<ruby>`、`<c.className>`）
/// 与增强 LRC 词级时间标签（`<MM:SS.xx>`）同形，统一按此模式剥离。
final RegExp _inlineTagPattern = RegExp('<[^>]+>');

/// 剥离字幕文本中的 `<...>` 行内标签：仅移除标签本身、保留标签内文本，
/// 并去除首尾空白。例如 `<i>こんにちは</i>` → `こんにちは`。
///
/// 注意：hibiki_anki 的 `BaseAnkiRepository.previewFromFieldValue` 有一份
/// **故意不同**的实现——那边把标签替换成**空格**再统一折叠（Anki 字段 HTML 里
/// `<br>` / 块级标签承担换行分词，直接删空会把相邻词粘连）；而字幕行内标签
/// 紧贴正文，替换成空格反而会在日文句中引入假空格。两份实现不强并。
String stripHtmlTags(String text) =>
    text.replaceAll(_inlineTagPattern, '').trim();
