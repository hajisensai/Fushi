/// 卡面外观定制页预览用的样例笔记（Fushi 卡片字段，按字段名）。
///
/// 释义是手写的 Yomitan 导出同形 HTML（`.yomitan-glossary > ol > li[data-dictionary]`，结构化
/// 内容带 inline 颜色 / 底色 / 描框），专门覆盖统一词典样式的几类语义：彩色词性标签（chip）、
/// 描框标签（chip-outline）、彩色强调字（accent）、浅底例句块（panel）、深底大字框（block）。
/// 不含任何真实词典内容；图片是内联 SVG（data URI），不依赖媒体库。
library;

import 'package:fushi_anki/fushi_anki_core.dart';

const String _sampleDictA = 'Fushi 示例国語辞典';
const String _sampleDictB = 'Fushi 示例日中辞典';

// 注意：图里不能用 `url(#id)` 引用（渐变等）——卡面的媒体改写会把 HTML 里任何 `url(x)`
// 当成媒体库引用改写，打断 data URI。只用纯色块。
const String _samplePicture =
    '<img alt="" src="data:image/svg+xml;utf8,'
    '%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%22320%22 height=%22200%22 viewBox=%220 0 320 200%22%3E'
    '%3Crect width=%22320%22 height=%22200%22 fill=%22%237fa892%22/%3E'
    '%3Crect y=%22110%22 width=%22320%22 height=%2290%22 fill=%22%23386a58%22/%3E'
    '%3Ccircle cx=%22238%22 cy=%2262%22 r=%2228%22 fill=%22%23f4f1e8%22 opacity=%220.85%22/%3E'
    '%3Cpath d=%22M0 170 L90 110 L150 150 L230 90 L320 160 L320 200 L0 200Z%22 '
    'fill=%22%23203d32%22 opacity=%220.7%22/%3E%3C/svg%3E">';

String _li(String dict, String tags, String body) =>
    '<li data-dictionary="$dict"><i>($tags$dict)</i> <span>'
    '<span class="structured-content">$body</span></span></li>';

const String _chipRed =
    '<span class="gloss-sc-span" style="background-color:#c8343a;color:#ffffff;'
    'border-radius:3px;padding:0 0.2em;font-size:0.85em">';
const String _boxed =
    '<span class="gloss-sc-span" style="border:1px solid #c8343a;color:#c8343a;'
    'font-size:0.85em;padding:0 0.2em">';
const String _accentBlue = '<span class="gloss-sc-span" style="color:#1f5fbf">';
const String _panel =
    '<div class="gloss-sc-div" style="background-color:#f3eedb;padding:0.3em 0.5em;'
    'margin-top:0.3em;border-radius:4px">';
const String _block =
    '<span class="gloss-sc-span" style="background-color:#5a2a82;color:#ffffff;'
    'font-size:1.6em;padding:0 0.15em">';

/// 主释义（第一部词典）。
final String kSrsSampleMainDefinition =
    '<div style="text-align: left;" class="yomitan-glossary"><ol>'
    '${_li(_sampleDictA, '', '$_block通</span> かよ・う【通う】 '
        '$_chipRed動五</span> $_boxed自</span><br>'
        '① 同じ場所へ何度も行き来する。$_accentBlue「学校に─」</span><br>'
        '② 気持ちや考えが相手に伝わる。'
        '$_panel例：心が─・う友人。</div>')}'
    '</ol></div>';

/// 全部释义（含主释义那部词典，卡面脚本会去重）。
final String kSrsSampleGlossary =
    '<div style="text-align: left;" class="yomitan-glossary"><ol>'
    '${_li(_sampleDictA, '', '$_block通</span> かよ・う【通う】 '
        '$_chipRed動五</span> $_boxed自</span><br>'
        '① 同じ場所へ何度も行き来する。$_accentBlue「学校に─」</span><br>'
        '② 気持ちや考えが相手に伝わる。'
        '$_panel例：心が─・う友人。</div>')}'
    '${_li(_sampleDictB, 'v5u, ', '<span lang="zh-CN">'
        '$_chipRed五段</span> ①（定期地）往返，来往；上（学、班）。'
        '$_accentBlue学校に通う</span>：上学。<br>'
        '② 相通，流通；心意相通。</span>')}'
    '${_li(_sampleDictB, 'n, ', '<span lang="zh-CN">'
        '③〔血液などが〕流通，循环。</span>')}'
    '</ol></div>';

/// 样例笔记的字段（Fushi 卡片字段名 → 内容）。
Map<String, String> srsSampleCardFields() => <String, String>{
  for (final String f in FushiCardNoteType.fields) f: '',
  'Expression': '通う',
  'ExpressionFurigana': '通[かよ]う',
  'ExpressionReading': 'かよう',
  'Sentence': '毎日のように図書館に<b>通って</b>いる。',
  'SentenceFurigana': '毎日[まいにち]のように 図書館[としょかん]に<b>通[かよ]って</b>いる。',
  'SentenceTranslation': '几乎每天都去图书馆。',
  'Picture': _samplePicture,
  'MainDefinition': kSrsSampleMainDefinition,
  'Glossary': kSrsSampleGlossary,
  'PitchPosition':
      '<ul><li><span style="display:inline;"><span>[</span><span>0</span>'
      '<span>]</span></span></li></ul>',
  'PitchCategories': 'heiban',
  'Frequency':
      '<ul style="text-align: left;"><li>JPDB: 1840</li><li>Novels: 2213</li></ul>',
  'FreqSort': '1840',
  'MiscInfo': '<a href="#">Fushi 示例书</a>',
  'IsWordAndSentenceCard': 'x',
};
