/// 制卡「紧凑释义」（Anki 设置 `AnkiSettings.compactGlossaries`，对齐 Yomitan 的
/// Compact Popup and Anki）在导出释义 HTML 上的唯一落地点（BUG-2700 / issue #1432）。
///
/// 此前开关只被写入和显示：popup.js 导出释义时判断的是 `window.compactGlossariesAnki`，
/// 而生产代码从来没有给它赋过值，于是开了也等于没开。弹窗 JS 看不见 Anki 设置，
/// 真正握着 `AnkiSettings` 的是各制卡后端组装字段的那一步，所以样式改在 Dart 侧、
/// 在 payload 进 handlebar 渲染之前注入；关闭时原样返回，输出逐字节不变。
library;

/// 与 Yomitan 同语义的紧凑释义样式：义项列表改成行内、项与项之间用灰色 ` | ` 分隔。
///
/// 从 popup.js 原 `COMPACT_GLOSSARIES_ANKI` 常量原样挪来（选择器限定在导出释义的
/// `.yomitan-glossary` 容器内，不波及卡片其它部分）。
const String kCompactGlossariesAnkiCss =
    '.yomitan-glossary ul[data-sc-content="glossary"] > li:not(:first-child)::before, '
    '.yomitan-glossary .glossary-list > li:not(:first-child)::before '
    '{ white-space: pre-wrap; content: " | "; display: inline; color: rgb(119, 119, 119); }\n'
    '.yomitan-glossary ul[data-sc-content="glossary"] > li, '
    '.yomitan-glossary .glossary-list > li { display: inline; }\n'
    '.yomitan-glossary ul[data-sc-content="glossary"], '
    '.yomitan-glossary .glossary-list '
    '{ display: inline; list-style: none; padding-left: 0px; }';

const String _compactStyleTag = '<style>$kCompactGlossariesAnkiCss</style>';
const String _closingDiv = '</div>';

/// 给一段导出释义 HTML 加上紧凑样式；[enabled] 为 false 或 [html] 为空时原样返回。
///
/// popup.js 导出的每段释义都是 `<div class="yomitan-glossary">…</div>`，词典样式的
/// `<style>` 也放在这个容器的收尾之前；紧凑样式同样插在最后一个 `</div>` 之前，
/// 与原 JS 分支的产物逐字节一致。形状不符（外部发送端）时退化为追加在末尾。
/// 已含紧凑样式的不重复注入。
String compactAnkiGlossaryHtml(String html, {required bool enabled}) {
  if (!enabled || html.isEmpty || html.contains(_compactStyleTag)) {
    return html;
  }
  if (html.endsWith(_closingDiv)) {
    final int at = html.length - _closingDiv.length;
    return '${html.substring(0, at)}$_compactStyleTag$_closingDiv';
  }
  return '$html$_compactStyleTag';
}

/// [compactAnkiGlossaryHtml] 的逐词典版本（`AnkiMiningPayload.singleGlossaries`）。
/// [enabled] 为 false 时返回同一个 Map 实例。
Map<String, String> compactAnkiGlossaryMap(
  Map<String, String> glossaries, {
  required bool enabled,
}) {
  if (!enabled || glossaries.isEmpty) return glossaries;
  return <String, String>{
    for (final MapEntry<String, String> e in glossaries.entries)
      e.key: compactAnkiGlossaryHtml(e.value, enabled: true),
  };
}
