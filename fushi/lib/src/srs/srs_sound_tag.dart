/// Anki 声音标记 `[sound:x]` 的词法、标记里文件名的解码，以及拼卡面 HTML 用的转义。
///
/// 卡面的三套渲染（整面 WebView 把标记改写成按钮、原生 Fushi 卡面与原生 HTML 卡面各画一颗
/// 发音键）、宿主的自动播放 / 重播清单、远程刷卡的媒体预取、字段编辑器、浏览检查器都只认
/// 这一处的正则与转义（以前各抄一份）。
///
/// 纯 Dart，没有依赖，可在任何 isolate 跑。
library;

/// `[sound:x]`。组 1 是标记里的原始文件名（没去空白、没解实体），取名字用 [srsSoundTagName]。
final RegExp srsSoundTagPattern = RegExp(r'\[sound:([^\]]+)\]');

/// 媒体引用（文件名、`src` 值）里的 HTML 实体还原：Anki 的字段是 HTML，文件名里的 `&` 存成
/// `&amp;`，引号与尖括号同理。`&amp;` 最后解（`&amp;lt;` 是字面的 `&lt;`）。
String srsUnescapeMediaName(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// [raw]（[srsSoundTagPattern] 的组 1）对应的媒体库文件名：去首尾空白、解实体。
String srsSoundTagName(String raw) => srsUnescapeMediaName(raw.trim());

/// HTML 转义（`& " < >`）：双引号属性的值与元素里的文字都用它。
String srsEscapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
