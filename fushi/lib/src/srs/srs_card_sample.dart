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

// 320×200 的 PNG（风景色块，约 1 KB）：WebView 卡面与原生卡面（Image.memory）都能直接显示。
// 不用 SVG——原生侧不带 SVG 渲染器。
const String _samplePicture =
    '<img alt="" src="data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAUAAAADICAIAAAAWZq/8AAAD0ElEQVR42u3dsW0UUBRE0enGLZC4ARJSJ26AJuiBKtyTMwLqcGCJCEskSJ55R7oVvPlHuxttfrz8lFRanEACWBLAkgCWAJYEsCSAJQEsASwJYEkASwBLAlgSwJIAlgCWBLAkgCUBLAEsCWBJAEsASwJYEsCSAJYAlgSwJIAlASwBLAlgSQBLAEt1/fr9CrDUYfXfA1jqc3tEMsDapzvMGGBdoTvJGGCd07tkGGCdo7vEGGDd1TtgGGCd1ttuGGBd11ttGGDRW2wYYNFbbBhgAQyw1K+30TDAorfYMMACGGBpRW+XYYAFMMDSkN4iwwALYIAlgAEWvQwDLIABlgAGWAIYYAEMMMACGGAJYIBFL8MAi2GfwBLAAEsAAyyAAQZYAAMsAQywBDDAYphegAUwwBLAAIthegEWwABLDPtnBglggMUwvQCLYf8PLAEMsPR5DTceDWAx3KoXYDFcrBdgMfxafSuAddpw+6EA1lHGGycCWBcNz9wHYN1iPHYZgHWF8eRNANa45O1TAKyyHp+/faT64DUAVpne95wCYLXqZRhgFdNlGGDV68UYYNXrPW4YYHXTPW4YYC3oPcsYYO3oPWgYYO3QPWgYYK3pPWUYYA3qvcMYYG3SPWIYYC3rnTcMsMb1bjMGWPt0hw0DrCt6Jw0DrEN69wwDrEN09xgDrIt6Zwzny/cn/enh66Mj/I+rftrabwvwX96ZU1ygu8EY4A/fmbMc0Vs9N8BPw9+v6J03HI9s/mcSusOG450xTG/v3PHIMKa3d+t4ZAyj27t1PDKM6e3dOh4Zw/T2bh0vDGN0e4eOR8Ywvb1DxwvDmN7eoeOFMYxu79DxwjCmt3fleGEM09s7dDwvjNHtXTleGMP09q4czwtjensnjufFMLq9KwddjOntnTj0Mkxv78RBF2N0eycOvQzT2ztx0MUYtt59Q+9lw4y17xt0zzKma2Df0HvTMFQb+wbda4xZWho39J4y7Lxj+wbdO4xddW/c0HthZsdcHTfozi/thsOGQ+/20q63zTjori7tYhcMh97Jpd3qiOGguze2E91hHHqXlnaZa4aD7szYDnLQcOjdGNspbhoOulIv49Ar9RoOulKv4dAr9TIOulKv4dAr9RoOulKv4dAr9TIOulKv4dAr9RoOulJvoVcaB+xMUitgN5IqAbuO1ArYaaRKwI4itQJ2EakSsFtIrYAdQqoE7AQSwJIAlgSwBLAkgCUBLAlgCWBJAEsCWAJYEsCSAJYEsASwJIAlASwJYAlgSQBLAlgCWBLAkgCWBLAEsCSAJQEsCWCpvDer8E/DJiRYIQAAAABJRU5ErkJggg=='
    '">';

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
  'Term': '通う',
  'TermFurigana': '通[かよ]う',
  'TermReading': 'かよう',
  'Sentence': '毎日のように図書館に<b>通って</b>いる。',
  'SentenceTranslation': '几乎每天都去图书馆。',
  'Media': _samplePicture,
  'MainDefinition': kSrsSampleMainDefinition,
  'Glossary': kSrsSampleGlossary,
  'PitchPosition':
      '<ul><li><span style="display:inline;"><span>[</span><span>0</span>'
      '<span>]</span></span></li></ul>',
  'PitchCategories': 'heiban',
  'Frequency':
      '<ul style="text-align: left;"><li>JPDB: 1840</li><li>Novels: 2213</li></ul>',
  'FrequencyRank': '1840',
  'Source': '<a href="#">Fushi 示例书</a>',
  'IsWordAndSentenceCard': 'x',
};
