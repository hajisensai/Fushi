/// 非 Fushi 卡片（Anki 导入牌组、用户自建类型）的**原生**渲染模型：把渲染器给出的卡面
/// HTML + 笔记类型 CSS 解析成带计算样式的盒子树，交给 `SrsHtmlCardView` 用 Flutter 画。
///
/// 判据（[srsHtmlCardOf]）：两面卡都只用了原生认得的 HTML / CSS 子集才原生，否则整张卡
/// 回退 WebView（与 Anki 一致的那条路）。不认识的东西一律不画近似样子：
/// - 标签：只认 [_kInlineTags] / [_kBlockTags] 里的，加上 `img`、`br`、`ruby` 系列与
///   `[sound:]`；`<script>`、事件属性（`onclick` …）、表格、表单、`<video>` / `<audio>`、SVG、
///   远程图片等一律回退；
/// - CSS：见 srs_html_card_css.dart（at-rule、未知属性 / 值 / 选择器回退）。
///
/// 层叠按浏览器的规则做：UA 默认样式 → 外壳样式（与 WebView 外壳同一份：`body` 16px 内边距、
/// 主题前景色）→ 笔记类型 CSS 与正文 `<style>` → `style` 属性，`!important` 反转，特异度 /
/// 先后定胜负，自定义属性（`var()`）按继承解析；`body` 挂 `card` 与 Anki 的夜间类名，
/// 正文是 `#qa` 的直接子节点（Anki reviewer 的 DOM 契约，与 WebView 外壳相同）。
///
/// 纯 Dart（不依赖 Flutter），可在任何 isolate 跑；按 HTML 内容记忆（[srsHtmlCardOf]）。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'package:fushi/src/srs/srs_html_card_css.dart';

export 'package:fushi/src/srs/srs_html_card_css.dart'
    show SrsCssLength, SrsCssUnit, SrsHtmlUnsupported;

// ---------------------------------------------------------------- 计算样式

enum SrsHtmlDisplay {
  block,
  inline,
  inlineBlock,
  flex,
  inlineFlex,
  listItem,
  none,
}

enum SrsHtmlTextAlign { start, left, right, center, justify }

enum SrsHtmlWhiteSpace { normal, nowrap, pre, preWrap, preLine }

enum SrsHtmlVerticalAlign { baseline, middle, top, bottom, sub, sup }

/// 一条边框（宽 0 = 没有）。
class SrsHtmlBorder {
  const SrsHtmlBorder(this.width, this.color);

  static const SrsHtmlBorder none = SrsHtmlBorder(0, 0);

  final double width;
  final int color;
}

/// 一个元素的计算样式（px 已换算；`%` / `vw` / `vh` 留在 [SrsCssLength] 里到排版时算）。
///
/// 构造后不再改（层叠时填好）。
class SrsHtmlStyle {
  SrsHtmlStyle._root({required this.color})
    : vars = const <String, String>{},
      fontSize = 16,
      fontWeight = 400,
      italic = false,
      fontFamilies = const <String>[],
      textAlign = SrsHtmlTextAlign.start,
      lineHeightFactor = null,
      lineHeightPx = null,
      letterSpacing = 0,
      whiteSpace = SrsHtmlWhiteSpace.normal,
      hidden = false,
      listStyle = 'disc',
      underline = false,
      lineThrough = false,
      overline = false;

  SrsHtmlStyle._inherit(SrsHtmlStyle p)
    : vars = p.vars,
      color = p.color,
      fontSize = p.fontSize,
      fontWeight = p.fontWeight,
      italic = p.italic,
      fontFamilies = p.fontFamilies,
      textAlign = p.textAlign,
      lineHeightFactor = p.lineHeightFactor,
      lineHeightPx = p.lineHeightPx,
      letterSpacing = p.letterSpacing,
      whiteSpace = p.whiteSpace,
      hidden = p.hidden,
      listStyle = p.listStyle,
      underline = p.underline,
      lineThrough = p.lineThrough,
      overline = p.overline;

  // 继承的
  Map<String, String> vars;
  int color;
  double fontSize;
  int fontWeight;
  bool italic;

  /// `font-family` 里的具体字族（通用族 `serif` / `sans-serif` 等已去掉）。
  List<String> fontFamilies;
  SrsHtmlTextAlign textAlign;
  double? lineHeightFactor;
  double? lineHeightPx;
  double letterSpacing;
  SrsHtmlWhiteSpace whiteSpace;
  bool hidden;
  String listStyle;
  bool underline;
  bool lineThrough;
  bool overline;

  // 不继承的
  SrsHtmlDisplay display = SrsHtmlDisplay.inline;
  int background = 0;

  /// 上右下左；null = `auto`。
  List<SrsCssLength?> margin = <SrsCssLength?>[
    SrsCssLength.zero,
    SrsCssLength.zero,
    SrsCssLength.zero,
    SrsCssLength.zero,
  ];
  List<SrsCssLength> padding = <SrsCssLength>[
    SrsCssLength.zero,
    SrsCssLength.zero,
    SrsCssLength.zero,
    SrsCssLength.zero,
  ];

  /// 上右下左。
  List<SrsHtmlBorder> border = <SrsHtmlBorder>[
    SrsHtmlBorder.none,
    SrsHtmlBorder.none,
    SrsHtmlBorder.none,
    SrsHtmlBorder.none,
  ];
  double radius = 0;

  /// null = auto。
  SrsCssLength? width;

  /// `width: fit-content / max-content`。
  bool fitContent = false;
  SrsCssLength? height;
  SrsCssLength? maxWidth;
  SrsCssLength? maxHeight;
  SrsCssLength? minHeight;
  double opacity = 1;
  bool flexColumn = false;
  bool flexWrap = false;
  String justify = 'flex-start';
  String alignItems = 'stretch';
  double rowGap = 0;
  double columnGap = 0;
  double flexGrow = 0;
  SrsHtmlVerticalAlign verticalAlign = SrsHtmlVerticalAlign.baseline;

  /// 行高（倍数）；null = normal。
  double? get lineHeight =>
      lineHeightPx != null ? lineHeightPx! / fontSize : lineHeightFactor;

  bool get hasBorder => border.any((SrsHtmlBorder b) => b.width > 0);

  bool get hasPadding => padding.any((SrsCssLength p) => p.value != 0);

  /// 行内元素需要当成一个盒子画（内边距 / 边框 / 圆角）。
  bool get boxed => hasPadding || hasBorder || (radius > 0 && background != 0);
}

// ---------------------------------------------------------------- 盒子树

/// 盒子树节点。
sealed class SrsHtmlNode {
  const SrsHtmlNode();
}

/// 块级盒子（含 flex 容器、列表项、`<details>`）。
class SrsHtmlBlock extends SrsHtmlNode {
  const SrsHtmlBlock({
    required this.tag,
    required this.style,
    required this.children,
    this.summary,
    this.detailsOpen = false,
    this.marker,
  });

  final String tag;
  final SrsHtmlStyle style;
  final List<SrsHtmlNode> children;

  /// `<details>` 的标题（[tag] == 'details' 时非 null）。
  final SrsHtmlBlock? summary;

  /// `<details open>`。
  final bool detailsOpen;

  /// 列表项的标记文字（`•`、`1.` …）；null = 不是列表项 / `list-style: none`。
  final String? marker;

  bool get isDetails => tag == 'details';
}

/// 一段行内内容（匿名块）：[style] 是所在块的样式（对齐 / 行高 / 空白处理）。
class SrsHtmlFlow extends SrsHtmlNode {
  const SrsHtmlFlow(this.inlines, this.style);

  final List<SrsHtmlInline> inlines;
  final SrsHtmlStyle style;
}

/// 行内内容。
sealed class SrsHtmlInline {
  const SrsHtmlInline();
}

class SrsHtmlTextRun extends SrsHtmlInline {
  SrsHtmlTextRun(this.text, this.style, {this.href, this.background = 0});

  String text;
  final SrsHtmlStyle style;
  final String? href;

  /// 所在行内元素的底色（没有内边距的 `<span style="background">`、`<mark>`）。
  final int background;
}

class SrsHtmlRubyRun extends SrsHtmlInline {
  const SrsHtmlRubyRun(
    this.base,
    this.reading,
    this.style,
    this.rubyStyle, {
    this.href,
  });

  final String base;
  final String reading;
  final SrsHtmlStyle style;
  final SrsHtmlStyle rubyStyle;
  final String? href;
}

class SrsHtmlImageRun extends SrsHtmlInline {
  const SrsHtmlImageRun(this.src, this.style, {this.href});

  /// 媒体库文件名或栅格 `data:` URL。
  final String src;
  final SrsHtmlStyle style;
  final String? href;
}

/// `[sound:]` 播放按钮。
class SrsHtmlSoundRun extends SrsHtmlInline {
  const SrsHtmlSoundRun(this.name);

  final String name;
}

class SrsHtmlBreakRun extends SrsHtmlInline {
  const SrsHtmlBreakRun();
}

/// 当成盒子画的行内元素（inline-block、带内边距 / 边框 / 圆角的 span）。
class SrsHtmlBoxRun extends SrsHtmlInline {
  const SrsHtmlBoxRun(this.box);

  final SrsHtmlBlock box;
}

// ---------------------------------------------------------------- 标签表

/// 行内标签（UA 默认 display: inline）。
const Set<String> _kInlineTags = <String>{
  'span',
  'a',
  'b',
  'strong',
  'i',
  'em',
  'u',
  'ins',
  's',
  'strike',
  'del',
  'small',
  'big',
  'sub',
  'sup',
  'code',
  'kbd',
  'samp',
  'tt',
  'var',
  'cite',
  'dfn',
  'abbr',
  'mark',
  'q',
  'font',
  'label',
  'time',
  'bdi',
  'bdo',
  'wbr',
  'data',
  'nobr',
};

/// 块级标签（UA 默认 display: block / list-item）。
const Set<String> _kBlockTags = <String>{
  'div',
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'ul',
  'ol',
  'li',
  'dl',
  'dt',
  'dd',
  'details',
  'summary',
  'hr',
  'blockquote',
  'center',
  'section',
  'article',
  'header',
  'footer',
  'main',
  'nav',
  'aside',
  'figure',
  'figcaption',
  'pre',
  'address',
  'hgroup',
};

/// 标签的 UA 默认样式（声明块）。
const Map<String, String> _kUaCss = <String, String>{
  'html': 'display:block',
  'body': 'display:block;margin:8px',
  'p': 'display:block;margin:1em 0',
  'h1': 'display:block;font-size:2em;margin:0.67em 0;font-weight:bold',
  'h2': 'display:block;font-size:1.5em;margin:0.83em 0;font-weight:bold',
  'h3': 'display:block;font-size:1.17em;margin:1em 0;font-weight:bold',
  'h4': 'display:block;margin:1.33em 0;font-weight:bold',
  'h5': 'display:block;font-size:0.83em;margin:1.67em 0;font-weight:bold',
  'h6': 'display:block;font-size:0.67em;margin:2.33em 0;font-weight:bold',
  'ul': 'display:block;margin:1em 0;padding-left:40px;list-style-type:disc',
  'ol': 'display:block;margin:1em 0;padding-left:40px;list-style-type:decimal',
  'li': 'display:list-item',
  'dl': 'display:block;margin:1em 0',
  'dd': 'display:block;margin-left:40px',
  'blockquote': 'display:block;margin:1em 40px',
  'figure': 'display:block;margin:1em 40px',
  'center': 'display:block;text-align:center',
  'pre': 'display:block;margin:1em 0;white-space:pre;font-family:monospace',
  'hr':
      'display:block;margin:0.5em 0;border-width:1px;border-style:inset;'
      'border-color:#808080',
  'address': 'display:block;font-style:italic',
  'b': 'font-weight:bold',
  'strong': 'font-weight:bold',
  'i': 'font-style:italic',
  'em': 'font-style:italic',
  'cite': 'font-style:italic',
  'var': 'font-style:italic',
  'dfn': 'font-style:italic',
  'u': 'text-decoration:underline',
  'ins': 'text-decoration:underline',
  's': 'text-decoration:line-through',
  'strike': 'text-decoration:line-through',
  'del': 'text-decoration:line-through',
  'small': 'font-size:smaller',
  'big': 'font-size:larger',
  'sub': 'font-size:smaller;vertical-align:sub',
  'sup': 'font-size:smaller;vertical-align:super',
  'code': 'font-family:monospace',
  'kbd': 'font-family:monospace',
  'samp': 'font-family:monospace',
  'tt': 'font-family:monospace',
  'mark': 'background-color:yellow;color:black',
  'a': 'color:#0000ee;text-decoration:underline',
  'rt': 'font-size:50%',
  'nobr': 'white-space:nowrap',
};

/// 外壳样式（与 WebView 外壳 `srsCardShellHtml` 同一份边距；前景色由主题给）。
String _shellCss(int foreground) {
  final double a = ((foreground >> 24) & 0xFF) / 255;
  return 'html,body{margin:0;padding:0;}body{padding:16px;}'
      'html,body{color:rgba(${(foreground >> 16) & 0xFF},'
      '${(foreground >> 8) & 0xFF},${foreground & 0xFF},$a);}';
}

// ---------------------------------------------------------------- 一面卡

final RegExp _soundTag = RegExp(r'\[sound:([^\]]+)\]');
final RegExp _scriptTag = RegExp(r'<script\b', caseSensitive: false);

String _escapeAttr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// 一面卡的原生渲染源：解析好的 DOM（`html > body.card > #qa > 正文`）+ 样式表。
class SrsHtmlCardFace {
  SrsHtmlCardFace._(this._doc, this._rules, this.languageCode);

  /// 解析一面卡；不支持时抛 [SrsHtmlUnsupported]。
  factory SrsHtmlCardFace.parse(
    String bodyHtml,
    String css, {
    String? languageCode,
  }) {
    if (_scriptTag.hasMatch(bodyHtml)) srsHtmlUnsupported('html: <script>');
    final String body = bodyHtml.replaceAllMapped(
      _soundTag,
      (Match m) =>
          '<fushi-sound data-name="${_escapeAttr(m.group(1)!.trim())}"></fushi-sound>',
    );
    final String lang = (languageCode ?? '').trim();
    final dom.Document doc = html_parser.parse(
      '<!doctype html><html><head></head><body class="card">'
      '<div id="qa"${lang.isEmpty ? '' : ' lang="${_escapeAttr(lang)}"'}>'
      '$body</div></body></html>',
    );
    final List<String> bodyStyles = <String>[];
    for (final dom.Element st in doc.querySelectorAll('style').toList()) {
      final String type = (st.attributes['type'] ?? 'text/css').toLowerCase();
      if (st.attributes.containsKey('media') || type != 'text/css') {
        srsHtmlUnsupported('html: <style> with attributes');
      }
      bodyStyles.add(st.text);
      st.remove();
    }
    // 解析器把 `<link>` / `<meta>` 等挪进 head：卡面里出现就不支持。
    final dom.Element? head = doc.head;
    if (head != null && head.children.isNotEmpty) {
      srsHtmlUnsupported('html: <${head.children.first.localName}>');
    }
    final List<SrsCssRule> rules = <SrsCssRule>[
      ...srsParseStylesheet(css, orderBase: 0),
    ];
    for (final String s in bodyStyles) {
      rules.addAll(srsParseStylesheet(s, orderBase: rules.length + 1));
    }
    return SrsHtmlCardFace._(doc, rules, lang.isEmpty ? null : lang);
  }

  final dom.Document _doc;
  final List<SrsCssRule> _rules;

  /// 卡面 `lang`（字形回落链按它选）。
  final String? languageCode;

  final Map<String, SrsHtmlBlock> _layouts = <String, SrsHtmlBlock>{};

  /// 按主题算出的盒子树（根是 `body`）。[foreground] 是主题前景色（ARGB），[dark] 决定
  /// `body` 上有没有 Anki 的夜间类名；[hostCss] 是宿主追加的样式（卡面图片大小）。
  /// 结果按参数记忆。不支持时抛 [SrsHtmlUnsupported]。
  SrsHtmlBlock layout({
    required bool dark,
    required int foreground,
    String hostCss = '',
  }) {
    final String key = '$dark\u0000$foreground\u0000$hostCss';
    final SrsHtmlBlock? hit = _layouts[key];
    if (hit != null) return hit;
    final dom.Element body = _doc.body!;
    body.attributes['class'] = dark ? 'card nightMode night_mode' : 'card';
    final List<SrsCssRule> shell = srsParseStylesheet(
      _shellCss(foreground),
      orderBase: -100000,
    );
    final List<SrsCssRule> host = hostCss.isEmpty
        ? const <SrsCssRule>[]
        : srsParseStylesheet(hostCss, orderBase: 1000000);
    final _Cascade cascade = _Cascade(<SrsCssRule>[
      ...shell,
      ..._rules,
      ...host,
    ], foreground);
    final SrsHtmlStyle htmlStyle = cascade.compute(
      _doc.documentElement!,
      SrsHtmlStyle._root(color: foreground),
    );
    cascade.rem = htmlStyle.fontSize;
    final SrsHtmlStyle bodyStyle = cascade.compute(body, htmlStyle);
    final SrsHtmlBlock out = _Builder(cascade).block(body, bodyStyle);
    if (_layouts.length > 6) _layouts.remove(_layouts.keys.first);
    _layouts[key] = out;
    return out;
  }
}

/// 一张卡的两面（[srsHtmlCardOf]）。
class SrsHtmlCard {
  const SrsHtmlCard(this.question, this.answer);

  final SrsHtmlCardFace question;
  final SrsHtmlCardFace answer;

  SrsHtmlCardFace face({required bool answerSide}) =>
      answerSide ? answer : question;
}

final Map<String, ({SrsHtmlCard? card, String? reason})> _cardMemo =
    <String, ({SrsHtmlCard? card, String? reason})>{};

/// 这张卡能不能原生画：两面都能（明暗两种主题下都解析得了）才给出 [SrsHtmlCard]，否则
/// null（整张卡回退 WebView）。按内容记忆最近 12 张。
SrsHtmlCard? srsHtmlCardOf({
  required String question,
  required String answer,
  required String css,
  String? languageCode,
}) => srsHtmlCardProbe(
  question: question,
  answer: answer,
  css: css,
  languageCode: languageCode,
).card;

/// [srsHtmlCardOf] 带上回退原因（日志 / 测试）。
({SrsHtmlCard? card, String? reason}) srsHtmlCardProbe({
  required String question,
  required String answer,
  required String css,
  String? languageCode,
}) {
  final String key =
      '${languageCode ?? ''}\u0000$css\u0000$question\u0000$answer';
  final ({SrsHtmlCard? card, String? reason})? hit = _cardMemo.remove(key);
  if (hit != null) {
    _cardMemo[key] = hit;
    return hit;
  }
  ({SrsHtmlCard? card, String? reason}) result;
  try {
    final SrsHtmlCard card = SrsHtmlCard(
      SrsHtmlCardFace.parse(question, css, languageCode: languageCode),
      SrsHtmlCardFace.parse(answer, css, languageCode: languageCode),
    );
    for (final SrsHtmlCardFace f in <SrsHtmlCardFace>[
      card.question,
      card.answer,
    ]) {
      f.layout(dark: false, foreground: 0xFF000000);
      f.layout(dark: true, foreground: 0xFFFFFFFF);
    }
    result = (card: card, reason: null);
  } on SrsHtmlUnsupported catch (e) {
    result = (card: null, reason: e.reason);
  }
  _cardMemo[key] = result;
  if (_cardMemo.length > 12) _cardMemo.remove(_cardMemo.keys.first);
  return result;
}

/// 这面卡**看得见**的 `[sound:]`（文档顺序、保留重复）：`display:none` 的不在树里，收起的
/// `<details>` 里的不算（与 WebView 卡面上报的可见发音同一口径）。
List<String> srsHtmlVisibleSounds(SrsHtmlBlock root) {
  final List<String> out = <String>[];
  _collectSounds(root, out);
  return out;
}

void _collectSounds(SrsHtmlNode n, List<String> out) {
  switch (n) {
    case SrsHtmlBlock():
      if (n.isDetails) {
        _collectSounds(n.summary!, out);
        if (!n.detailsOpen) return;
      }
      for (final SrsHtmlNode c in n.children) {
        _collectSounds(c, out);
      }
    case SrsHtmlFlow(:final List<SrsHtmlInline> inlines):
      for (final SrsHtmlInline r in inlines) {
        switch (r) {
          case SrsHtmlSoundRun(:final String name):
            out.add(name);
          case SrsHtmlBoxRun(:final SrsHtmlBlock box):
            _collectSounds(box, out);
          default:
            break;
        }
      }
  }
}

// ---------------------------------------------------------------- 层叠

class _Cascade {
  _Cascade(this.rules, this.foreground);

  final List<SrsCssRule> rules;
  final int foreground;
  double rem = 16;

  final Map<String, List<SrsCssDeclaration>> _uaMemo =
      <String, List<SrsCssDeclaration>>{};

  List<SrsCssDeclaration> _ua(String tag) => _uaMemo.putIfAbsent(
    tag,
    () => _kUaCss[tag] == null
        ? const <SrsCssDeclaration>[]
        : srsParseDeclarations(_kUaCss[tag]!),
  );

  /// 元素 [e] 的计算样式（父样式 [parent]）。
  SrsHtmlStyle compute(dom.Element e, SrsHtmlStyle parent) {
    final String tag = e.localName ?? '';
    for (final Object key in e.attributes.keys) {
      final String name = key.toString();
      if (name.toLowerCase().startsWith('on')) {
        srsHtmlUnsupported('html: event handler $name');
      }
    }
    // (important, origin, specificity, order, decl)
    final List<(int, int, int, int, SrsCssDeclaration)> found =
        <(int, int, int, int, SrsCssDeclaration)>[];
    int ua = 0;
    for (final SrsCssDeclaration d in _ua(tag)) {
      found.add((0, 0, 0, ua++, d));
    }
    final List<SrsCssDeclaration> presentational = _presentational(e, tag);
    for (final SrsCssDeclaration d in presentational) {
      found.add((0, 1, 0, ua++, d));
    }
    for (final SrsCssRule r in rules) {
      if (!r.selector.matches(e)) continue;
      for (final SrsCssDeclaration d in r.declarations) {
        found.add((d.important ? 1 : 0, 2, r.selector.specificity, r.order, d));
      }
    }
    final String? inline = e.attributes['style'];
    if (inline != null && inline.trim().isNotEmpty) {
      int i = 0;
      for (final SrsCssDeclaration d in srsParseDeclarations(inline)) {
        found.add((d.important ? 1 : 0, 3, 0, i++, d));
      }
    }
    found.sort((a, b) {
      int c = a.$1.compareTo(b.$1);
      if (c != 0) return c;
      // !important 时作者样式胜过行内？不：行内 important 仍最高（origin 3 > 2）。
      c = a.$2.compareTo(b.$2);
      if (c != 0) return c;
      c = a.$3.compareTo(b.$3);
      if (c != 0) return c;
      return a.$4.compareTo(b.$4);
    });
    final Map<String, String> props = <String, String>{};
    for (final (int, int, int, int, SrsCssDeclaration) f in found) {
      props[f.$5.property] = f.$5.value;
    }
    final SrsHtmlStyle s = SrsHtmlStyle._inherit(parent);
    // 自定义属性：继承 + 本元素声明的（值里的 var() 用到时再解）。
    final Map<String, String> ownVars = <String, String>{
      for (final MapEntry<String, String> p in props.entries)
        if (p.key.startsWith('--')) p.key: p.value,
    };
    if (ownVars.isNotEmpty) {
      s.vars = <String, String>{...parent.vars, ...ownVars};
    }
    String? get(String p) {
      final String? raw = props[p];
      if (raw == null) return null;
      return srsCssResolveVars(raw, s.vars).trim();
    }

    _apply(s, parent, get, tag);
    if (e.attributes.containsKey('hidden')) s.display = SrsHtmlDisplay.none;
    return s;
  }

  /// HTML 呈现属性（`<font color>`、`align`、`<img width>`）当作特异度 0 的作者样式。
  List<SrsCssDeclaration> _presentational(dom.Element e, String tag) {
    final StringBuffer css = StringBuffer();
    final Map<Object, String> a = e.attributes;
    if (tag == 'font') {
      if (a['color'] != null) css.write('color:${a['color']};');
      if (a['face'] != null) css.write('font-family:${a['face']};');
      final int? size = int.tryParse((a['size'] ?? '').trim());
      if (size != null) {
        const List<int> px = <int>[10, 13, 16, 18, 24, 32, 48];
        css.write('font-size:${px[(size - 1).clamp(0, 6)]}px;');
      }
    }
    final String? align = a['align'];
    if (align != null && tag != 'img') {
      css.write('text-align:${align.trim().toLowerCase()};');
    }
    if (tag == 'img') {
      String dim(String v) =>
          RegExp(r'^\d+(\.\d+)?$').hasMatch(v.trim()) ? '${v.trim()}px' : v;
      if (a['width'] != null) css.write('width:${dim(a['width']!)};');
      if (a['height'] != null) css.write('height:${dim(a['height']!)};');
    }
    final String bg = a['bgcolor'] ?? '';
    if (bg.isNotEmpty) css.write('background-color:$bg;');
    return css.isEmpty
        ? const <SrsCssDeclaration>[]
        : srsParseDeclarations(css.toString());
  }

  void _apply(
    SrsHtmlStyle s,
    SrsHtmlStyle p,
    String? Function(String) get,
    String tag,
  ) {
    bool kw(String? v, String k) => v != null && v.toLowerCase() == k;
    bool inherit(String? v) => kw(v, 'inherit') || kw(v, 'unset');

    // 字号先算（其余 em 都按它）。
    final String? fs = get('font-size');
    if (fs != null && !inherit(fs)) {
      s.fontSize = _fontSize(fs, p.fontSize);
    }
    final double em = s.fontSize;
    SrsCssLength len(String v, {bool percent = true, bool viewport = true}) =>
        srsCssParseLength(
          v,
          em: em,
          rem: rem,
          allowPercent: percent,
          allowViewport: viewport,
        );

    final String? color = get('color');
    if (color != null && !inherit(color)) {
      s.color = kw(color, 'initial')
          ? foreground
          : srsCssParseColor(color, current: p.color);
    }
    final String? fw = get('font-weight');
    if (fw != null && !inherit(fw)) {
      s.fontWeight = _fontWeight(fw, p.fontWeight);
    }
    final String? fst = get('font-style');
    if (fst != null && !inherit(fst)) {
      s.italic =
          fst.toLowerCase() == 'italic' || fst.toLowerCase() == 'oblique';
    }
    final String? ff = get('font-family');
    if (ff != null && !inherit(ff)) s.fontFamilies = srsCssFontFamilies(ff);
    final String? ta = get('text-align');
    if (ta != null && !inherit(ta)) {
      s.textAlign = switch (ta.toLowerCase()) {
        'left' => SrsHtmlTextAlign.left,
        'right' => SrsHtmlTextAlign.right,
        'center' ||
        '-webkit-center' ||
        '-moz-center' => SrsHtmlTextAlign.center,
        'justify' => SrsHtmlTextAlign.justify,
        'start' || 'initial' => SrsHtmlTextAlign.start,
        'end' => SrsHtmlTextAlign.right,
        'match-parent' => p.textAlign,
        _ => srsHtmlUnsupported('css: text-align "$ta"'),
      };
    }
    final String? lh = get('line-height');
    if (lh != null && !inherit(lh)) {
      final String v = lh.toLowerCase();
      if (v == 'normal' || v == 'initial') {
        s.lineHeightFactor = null;
        s.lineHeightPx = null;
      } else if (double.tryParse(v) != null) {
        s.lineHeightFactor = double.parse(v);
        s.lineHeightPx = null;
      } else {
        final SrsCssLength l = len(v, viewport: false);
        s.lineHeightPx = l.unit == SrsCssUnit.percent
            ? em * l.value / 100
            : l.value;
        s.lineHeightFactor = null;
      }
    }
    final String? ls = get('letter-spacing');
    if (ls != null && !inherit(ls)) {
      s.letterSpacing = kw(ls, 'normal') || kw(ls, 'initial')
          ? 0
          : len(ls, percent: false, viewport: false).value;
    }
    final String? ws = get('white-space');
    if (ws != null && !inherit(ws)) {
      s.whiteSpace = switch (ws.toLowerCase()) {
        'normal' || 'initial' => SrsHtmlWhiteSpace.normal,
        'nowrap' => SrsHtmlWhiteSpace.nowrap,
        'pre' => SrsHtmlWhiteSpace.pre,
        'pre-wrap' || 'break-spaces' => SrsHtmlWhiteSpace.preWrap,
        'pre-line' => SrsHtmlWhiteSpace.preLine,
        _ => srsHtmlUnsupported('css: white-space "$ws"'),
      };
    }
    final String? vis = get('visibility');
    if (vis != null && !inherit(vis)) {
      s.hidden = switch (vis.toLowerCase()) {
        'visible' || 'initial' => false,
        'hidden' || 'collapse' => true,
        _ => srsHtmlUnsupported('css: visibility "$vis"'),
      };
    }
    final String? lst = get('list-style-type');
    if (lst != null && !inherit(lst)) {
      const Set<String> ok = <String>{
        'disc',
        'circle',
        'square',
        'decimal',
        'none',
        'lower-alpha',
        'upper-alpha',
        'lower-latin',
        'upper-latin',
      };
      if (!ok.contains(lst.toLowerCase())) {
        srsHtmlUnsupported('css: list-style-type "$lst"');
      }
      s.listStyle = lst.toLowerCase();
    }
    final String? td = get('text-decoration-line');
    if (td != null && !inherit(td)) {
      final List<String> lines = srsCssValueParts(td.toLowerCase());
      // 祖先的装饰线照样画在子孙上（none 去不掉），只加不减。
      if (lines.contains('underline')) s.underline = true;
      if (lines.contains('line-through')) s.lineThrough = true;
      if (lines.contains('overline')) s.overline = true;
    }

    // ---- 不继承的
    final String? display = get('display');
    final String defaultDisplay = tag == 'li'
        ? 'list-item'
        : _kBlockTags.contains(tag) || tag == 'html' || tag == 'body'
        ? 'block'
        : tag == 'rp'
        ? 'none'
        : 'inline';
    final String dv =
        display == null || inherit(display) || kw(display, 'initial')
        ? defaultDisplay
        : display.toLowerCase();
    s.display = switch (dv) {
      'block' => SrsHtmlDisplay.block,
      'inline' => SrsHtmlDisplay.inline,
      'inline-block' => SrsHtmlDisplay.inlineBlock,
      'flex' => SrsHtmlDisplay.flex,
      'inline-flex' => SrsHtmlDisplay.inlineFlex,
      'list-item' => SrsHtmlDisplay.listItem,
      'none' => SrsHtmlDisplay.none,
      _ => srsHtmlUnsupported('css: display "$dv"'),
    };
    final String? bg = get('background-color');
    if (bg != null && !inherit(bg) && !kw(bg, 'initial')) {
      s.background = srsCssParseColor(bg, current: s.color);
    }
    const List<String> sides = <String>['top', 'right', 'bottom', 'left'];
    for (int i = 0; i < 4; i++) {
      final String? m = get('margin-${sides[i]}');
      if (m != null && !inherit(m)) {
        s.margin[i] = kw(m, 'auto') ? null : len(m);
      }
      final String? pd = get('padding-${sides[i]}');
      if (pd != null && !inherit(pd)) s.padding[i] = len(pd);
      final String? bs = get('border-${sides[i]}-style');
      final String? bw = get('border-${sides[i]}-width');
      final String? bc = get('border-${sides[i]}-color');
      final String style = (bs ?? 'none').toLowerCase();
      if (style != 'none' && style != 'hidden') {
        if (!const <String>{
          'solid',
          'dashed',
          'dotted',
          'double',
          'groove',
          'ridge',
          'inset',
          'outset',
        }.contains(style)) {
          srsHtmlUnsupported('css: border-style "$style"');
        }
        final double width = switch ((bw ?? 'medium').toLowerCase()) {
          'thin' => 1,
          'medium' => 3,
          'thick' => 5,
          final String v => len(v, percent: false, viewport: false).value,
        };
        s.border[i] = SrsHtmlBorder(
          width,
          srsCssParseColor(bc ?? 'currentcolor', current: s.color),
        );
      }
    }
    final String? br = get('border-radius');
    if (br != null && !inherit(br) && !kw(br, 'initial')) {
      final List<String> parts = srsCssValueParts(br.split('/').first);
      final SrsCssLength r = len(parts.first, percent: false, viewport: false);
      s.radius = r.value;
    }
    final String? w = get('width');
    if (w != null && !inherit(w)) {
      final String v = w.toLowerCase();
      if (v == 'auto' || v == 'initial') {
        s.width = null;
      } else if (v == 'fit-content' ||
          v == 'max-content' ||
          v == '-webkit-fit-content' ||
          v == '-moz-fit-content') {
        s.fitContent = true;
      } else {
        s.width = len(v);
      }
    }
    final String? h = get('height');
    if (h != null && !inherit(h) && !kw(h, 'auto') && !kw(h, 'initial')) {
      if (tag != 'img') srsHtmlUnsupported('css: height on <$tag>');
      s.height = len(h, percent: false);
    }
    final String? mw = get('max-width');
    if (mw != null && !inherit(mw) && !kw(mw, 'none') && !kw(mw, 'initial')) {
      s.maxWidth = len(mw);
    }
    final String? mh = get('max-height');
    if (mh != null && !inherit(mh) && !kw(mh, 'none') && !kw(mh, 'initial')) {
      if (tag != 'img') srsHtmlUnsupported('css: max-height on <$tag>');
      s.maxHeight = len(mh, percent: false);
    }
    final String? minH = get('min-height');
    if (minH != null &&
        !inherit(minH) &&
        !kw(minH, 'auto') &&
        !kw(minH, 'initial')) {
      s.minHeight = len(minH, percent: false);
    }
    final String? op = get('opacity');
    if (op != null && !inherit(op)) {
      final double? o = double.tryParse(op.replaceAll('%', ''));
      if (o == null) srsHtmlUnsupported('css: opacity "$op"');
      s.opacity = (op.endsWith('%') ? o / 100 : o).clamp(0, 1);
    }
    final String? fd = get('flex-direction');
    if (fd != null && !inherit(fd)) {
      s.flexColumn = switch (fd.toLowerCase()) {
        'row' || 'initial' => false,
        'column' => true,
        _ => srsHtmlUnsupported('css: flex-direction "$fd"'),
      };
    }
    final String? fwr = get('flex-wrap');
    if (fwr != null && !inherit(fwr)) {
      s.flexWrap = switch (fwr.toLowerCase()) {
        'nowrap' || 'initial' => false,
        'wrap' => true,
        _ => srsHtmlUnsupported('css: flex-wrap "$fwr"'),
      };
    }
    final String? jc = get('justify-content');
    if (jc != null && !inherit(jc)) {
      final String v = jc.toLowerCase();
      if (!const <String>{
        'flex-start',
        'start',
        'left',
        'normal',
        'stretch',
        'initial',
        'center',
        'flex-end',
        'end',
        'right',
        'space-between',
        'space-around',
        'space-evenly',
      }.contains(v)) {
        srsHtmlUnsupported('css: justify-content "$jc"');
      }
      s.justify = v;
    }
    final String? ai = get('align-items');
    if (ai != null && !inherit(ai)) {
      final String v = ai.toLowerCase();
      if (!const <String>{
        'normal',
        'stretch',
        'initial',
        'flex-start',
        'start',
        'center',
        'flex-end',
        'end',
        'baseline',
      }.contains(v)) {
        srsHtmlUnsupported('css: align-items "$ai"');
      }
      s.alignItems = v;
    }
    final String? rg = get('row-gap');
    if (rg != null && !inherit(rg) && !kw(rg, 'normal')) {
      s.rowGap = len(rg, percent: false, viewport: false).value;
    }
    final String? cg = get('column-gap');
    if (cg != null && !inherit(cg) && !kw(cg, 'normal')) {
      s.columnGap = len(cg, percent: false, viewport: false).value;
    }
    final String? fg = get('flex-grow');
    if (fg != null && !inherit(fg)) {
      final double? g = double.tryParse(fg);
      if (g == null) srsHtmlUnsupported('css: flex-grow "$fg"');
      s.flexGrow = g;
    }
    final String? va = get('vertical-align');
    if (va != null && !inherit(va)) {
      s.verticalAlign = switch (va.toLowerCase()) {
        'baseline' || 'initial' => SrsHtmlVerticalAlign.baseline,
        'middle' => SrsHtmlVerticalAlign.middle,
        'top' || 'text-top' => SrsHtmlVerticalAlign.top,
        'bottom' || 'text-bottom' => SrsHtmlVerticalAlign.bottom,
        'sub' => SrsHtmlVerticalAlign.sub,
        'super' => SrsHtmlVerticalAlign.sup,
        _ => srsHtmlUnsupported('css: vertical-align "$va"'),
      };
    }
  }

  double _fontSize(String v, double parent) {
    final String l = v.toLowerCase();
    const Map<String, double> keywords = <String, double>{
      'xx-small': 9,
      'x-small': 10,
      'small': 13,
      'medium': 16,
      'large': 18,
      'x-large': 24,
      'xx-large': 32,
      'xxx-large': 48,
      'initial': 16,
    };
    final double? k = keywords[l];
    if (k != null) return k;
    if (l == 'smaller') return parent / 1.2;
    if (l == 'larger') return parent * 1.2;
    final SrsCssLength len = srsCssParseLength(
      l,
      em: parent,
      rem: rem,
      allowViewport: false,
    );
    return len.unit == SrsCssUnit.percent
        ? parent * len.value / 100
        : len.value;
  }

  int _fontWeight(String v, int parent) {
    switch (v.toLowerCase()) {
      case 'normal':
      case 'initial':
        return 400;
      case 'bold':
        return 700;
      case 'bolder':
        return parent < 350
            ? 400
            : parent < 550
            ? 700
            : 900;
      case 'lighter':
        return parent < 550
            ? 100
            : parent < 750
            ? 400
            : 700;
    }
    final int? n = int.tryParse(v);
    if (n == null || n < 1 || n > 1000) {
      srsHtmlUnsupported('css: font-weight "$v"');
    }
    return n;
  }
}

/// `font-family` → 具体字族（去引号；通用族去掉，`monospace` 除外——它换成常见等宽字体）。
List<String> srsCssFontFamilies(String value) {
  const Set<String> generic = <String>{
    'serif',
    'sans-serif',
    'cursive',
    'fantasy',
    'system-ui',
    '-apple-system',
    'blinkmacsystemfont',
    'ui-sans-serif',
    'ui-serif',
    'ui-rounded',
    'emoji',
    'math',
    'fangsong',
    'initial',
  };
  final List<String> out = <String>[];
  for (final String raw in srsCssSplitTopLevel(value, ',')) {
    String f = raw.trim();
    if (f.length >= 2 &&
        ((f.startsWith('"') && f.endsWith('"')) ||
            (f.startsWith("'") && f.endsWith("'")))) {
      f = f.substring(1, f.length - 1).trim();
    }
    if (f.isEmpty) continue;
    final String l = f.toLowerCase();
    if (l == 'monospace' || l == 'ui-monospace') {
      out.addAll(const <String>['Consolas', 'Menlo', 'Courier New']);
      continue;
    }
    if (generic.contains(l)) continue;
    out.add(f);
  }
  return out;
}

// ---------------------------------------------------------------- 盒子树构造

class _Builder {
  _Builder(this.cascade);

  final _Cascade cascade;

  SrsHtmlBlock block(dom.Element el, SrsHtmlStyle style) {
    final String tag = el.localName ?? '';
    if (tag == 'details') return _details(el, style);
    final List<SrsHtmlNode> children =
        style.display == SrsHtmlDisplay.flex ||
            style.display == SrsHtmlDisplay.inlineFlex
        ? _flexItems(el, style)
        : _children(el, style);
    return SrsHtmlBlock(
      tag: tag,
      style: style,
      children: children,
      marker: style.display == SrsHtmlDisplay.listItem
          ? _marker(el, style)
          : null,
    );
  }

  SrsHtmlBlock _details(dom.Element el, SrsHtmlStyle style) {
    dom.Element? summaryEl;
    for (final dom.Element c in el.children) {
      if (c.localName == 'summary') {
        summaryEl = c;
        break;
      }
    }
    final SrsHtmlBlock summary;
    if (summaryEl != null) {
      final SrsHtmlStyle ss = cascade.compute(summaryEl, style);
      summary = SrsHtmlBlock(
        tag: 'summary',
        style: ss,
        children: _children(summaryEl, ss),
      );
    } else {
      // 浏览器默认标题。
      final SrsHtmlStyle ss = SrsHtmlStyle._inherit(style)
        ..display = SrsHtmlDisplay.block;
      summary = SrsHtmlBlock(
        tag: 'summary',
        style: ss,
        children: <SrsHtmlNode>[
          SrsHtmlFlow(<SrsHtmlInline>[SrsHtmlTextRun('Details', ss)], ss),
        ],
      );
    }
    return SrsHtmlBlock(
      tag: 'details',
      style: style,
      summary: summary,
      detailsOpen: el.attributes.containsKey('open'),
      children: _children(el, style, skip: summaryEl),
    );
  }

  String? _marker(dom.Element el, SrsHtmlStyle style) {
    final String type = style.listStyle;
    if (type == 'none') return null;
    int index = 1;
    for (
      dom.Element? s = el.previousElementSibling;
      s != null;
      s = s.previousElementSibling
    ) {
      if (s.localName == 'li') index++;
    }
    final dom.Element? parent = el.parent;
    if (parent?.localName == 'ol') {
      index += (int.tryParse(parent!.attributes['start'] ?? '') ?? 1) - 1;
    }
    String alpha(int n) => String.fromCharCode(0x61 + (n - 1) % 26);
    return switch (type) {
      'disc' => '•',
      'circle' => '◦',
      'square' => '▪',
      'decimal' => '$index.',
      'lower-alpha' || 'lower-latin' => '${alpha(index)}.',
      'upper-alpha' || 'upper-latin' => '${alpha(index).toUpperCase()}.',
      _ => null,
    };
  }

  /// 块容器的子节点：连续的行内内容合成一段 [SrsHtmlFlow]。
  List<SrsHtmlNode> _children(
    dom.Element el,
    SrsHtmlStyle style, {
    dom.Element? skip,
  }) {
    final List<SrsHtmlNode> out = <SrsHtmlNode>[];
    List<SrsHtmlInline> inlines = <SrsHtmlInline>[];
    void flush() {
      final SrsHtmlFlow? flow = _finishFlow(inlines, style);
      if (flow != null) out.add(flow);
      inlines = <SrsHtmlInline>[];
    }

    for (final dom.Node n in el.nodes) {
      if (identical(n, skip)) continue;
      if (n is dom.Text) {
        inlines.add(SrsHtmlTextRun(n.data, style));
        continue;
      }
      if (n is! dom.Element) continue;
      final SrsHtmlStyle cs = _childStyle(n, style);
      switch (cs.display) {
        case SrsHtmlDisplay.none:
          break;
        case SrsHtmlDisplay.block:
        case SrsHtmlDisplay.listItem:
        case SrsHtmlDisplay.flex:
          if (_isAtomicInline(n)) {
            // `display:block` 的图片 / 发音键：独占一行的匿名段。
            flush();
            _inline(n, cs, inlines, href: null, background: 0);
            flush();
          } else {
            flush();
            out.add(block(n, cs));
          }
        case SrsHtmlDisplay.inline:
          _inline(n, cs, inlines, href: null, background: 0);
        case SrsHtmlDisplay.inlineBlock:
        case SrsHtmlDisplay.inlineFlex:
          if (_isAtomicInline(n)) {
            _inline(n, cs, inlines, href: null, background: 0);
          } else {
            inlines.add(SrsHtmlBoxRun(block(n, cs)));
          }
      }
    }
    flush();
    return out;
  }

  bool _isAtomicInline(dom.Element e) =>
      e.localName == 'img' ||
      e.localName == 'fushi-sound' ||
      e.localName == 'br';

  /// flex 容器的子项：每个子元素块级化成一项，直接的非空白文字成匿名项。
  List<SrsHtmlNode> _flexItems(dom.Element el, SrsHtmlStyle style) {
    final List<SrsHtmlNode> out = <SrsHtmlNode>[];
    List<SrsHtmlInline> text = <SrsHtmlInline>[];
    void flushText() {
      final SrsHtmlFlow? flow = _finishFlow(text, style);
      if (flow != null) out.add(flow);
      text = <SrsHtmlInline>[];
    }

    for (final dom.Node n in el.nodes) {
      if (n is dom.Text) {
        text.add(SrsHtmlTextRun(n.data, style));
        continue;
      }
      if (n is! dom.Element) continue;
      final SrsHtmlStyle cs = _childStyle(n, style);
      if (cs.display == SrsHtmlDisplay.none) continue;
      flushText();
      if (_isAtomicInline(n)) {
        final List<SrsHtmlInline> one = <SrsHtmlInline>[];
        _inline(n, cs, one, href: null, background: 0);
        final SrsHtmlFlow? flow = _finishFlow(one, style);
        if (flow != null) out.add(flow);
        continue;
      }
      if (cs.display == SrsHtmlDisplay.inline ||
          cs.display == SrsHtmlDisplay.inlineBlock) {
        cs.display = SrsHtmlDisplay.block;
      } else if (cs.display == SrsHtmlDisplay.inlineFlex) {
        cs.display = SrsHtmlDisplay.flex;
      }
      out.add(block(n, cs));
    }
    flushText();
    return out;
  }

  SrsHtmlStyle _childStyle(dom.Element n, SrsHtmlStyle parent) {
    final String tag = n.localName ?? '';
    if (!_kInlineTags.contains(tag) &&
        !_kBlockTags.contains(tag) &&
        !const <String>{
          'img',
          'br',
          'ruby',
          'rb',
          'rt',
          'rp',
          'rtc',
          'fushi-sound',
        }.contains(tag)) {
      srsHtmlUnsupported('html: <$tag>');
    }
    return cascade.compute(n, parent);
  }

  /// 行内元素 [el]（计算样式 [style]）的内容追加进 [out]。
  void _inline(
    dom.Element el,
    SrsHtmlStyle style,
    List<SrsHtmlInline> out, {
    required String? href,
    required int background,
  }) {
    final String tag = el.localName ?? '';
    final String? link = tag == 'a' && el.attributes['href'] != null
        ? el.attributes['href']!.trim()
        : href;
    switch (tag) {
      case 'br':
        out.add(const SrsHtmlBreakRun());
        return;
      case 'img':
        out.add(SrsHtmlImageRun(_imageSource(el), style, href: link));
        return;
      case 'fushi-sound':
        out.add(SrsHtmlSoundRun(el.attributes['data-name'] ?? ''));
        return;
      case 'ruby':
        _ruby(el, style, out, href: link);
        return;
    }
    if (style.boxed) {
      out.add(
        SrsHtmlBoxRun(block(el, style..display = SrsHtmlDisplay.inlineBlock)),
      );
      return;
    }
    final int bg = style.background != 0 ? style.background : background;
    for (final dom.Node n in el.nodes) {
      if (n is dom.Text) {
        out.add(SrsHtmlTextRun(n.data, style, href: link, background: bg));
        continue;
      }
      if (n is! dom.Element) continue;
      final SrsHtmlStyle cs = _childStyle(n, style);
      switch (cs.display) {
        case SrsHtmlDisplay.none:
          break;
        case SrsHtmlDisplay.inline:
          _inline(n, cs, out, href: link, background: bg);
        case SrsHtmlDisplay.inlineBlock:
        case SrsHtmlDisplay.inlineFlex:
          if (_isAtomicInline(n)) {
            _inline(n, cs, out, href: link, background: bg);
          } else {
            out.add(SrsHtmlBoxRun(block(n, cs)));
          }
        case SrsHtmlDisplay.block:
        case SrsHtmlDisplay.listItem:
        case SrsHtmlDisplay.flex:
          if (_isAtomicInline(n)) {
            _inline(n, cs, out, href: link, background: bg);
          } else {
            // 行内元素里套块（匿名块拆分）原生不做。
            srsHtmlUnsupported(
              'html: block <${n.localName}> inside inline <$tag>',
            );
          }
      }
    }
  }

  /// `<ruby>`：基字（`rb` / 文字）与紧随的 `<rt>` 配对；`<rp>` 丢掉。
  void _ruby(
    dom.Element el,
    SrsHtmlStyle style,
    List<SrsHtmlInline> out, {
    required String? href,
  }) {
    final StringBuffer base = StringBuffer();
    SrsHtmlStyle baseStyle = style;
    for (final dom.Node n in el.nodes) {
      if (n is dom.Text) {
        base.write(n.data);
        continue;
      }
      if (n is! dom.Element) continue;
      final String tag = n.localName ?? '';
      if (tag == 'rp') continue;
      if (tag == 'rt') {
        final SrsHtmlStyle rs = _childStyle(n, style);
        final String b = base.toString().trim();
        final String reading = n.text.trim();
        if (b.isNotEmpty) {
          out.add(SrsHtmlRubyRun(b, reading, baseStyle, rs, href: href));
        }
        base.clear();
        baseStyle = style;
        continue;
      }
      if (tag == 'rtc') srsHtmlUnsupported('html: <rtc>');
      final SrsHtmlStyle cs = _childStyle(n, style);
      if (cs.display == SrsHtmlDisplay.none) continue;
      if (n.querySelector('img, fushi-sound, ruby') != null) {
        srsHtmlUnsupported('html: media inside <ruby>');
      }
      // `<rb>` / `<b>` 等包着的基字：取最里层元素的样式（加粗的注音词）。
      SrsHtmlStyle inner = cs;
      dom.Element cur = n;
      while (cur.children.length == 1 &&
          cur.nodes.length == 1 &&
          cur.children.first.localName != 'rt') {
        cur = cur.children.first;
        inner = _childStyle(cur, inner);
      }
      baseStyle = inner;
      base.write(n.text);
    }
    final String rest = base.toString();
    if (rest.trim().isNotEmpty) {
      out.add(SrsHtmlTextRun(rest, baseStyle, href: href));
    }
  }

  String _imageSource(dom.Element img) {
    final String src = (img.attributes['src'] ?? '').trim();
    if (src.isEmpty) srsHtmlUnsupported('html: <img> without src');
    final String l = src.toLowerCase();
    if (l.startsWith('data:')) {
      if (!RegExp(
        r'^data:image/(png|jpe?g|gif|webp|bmp|avif)[;,]',
      ).hasMatch(l)) {
        srsHtmlUnsupported('html: data image "${l.split(',').first}"');
      }
      return src;
    }
    if (RegExp(r'^[a-z][a-z0-9+.\-]*:').hasMatch(l) || l.startsWith('//')) {
      srsHtmlUnsupported('html: remote image');
    }
    if (l.endsWith('.svg') || l.contains('/')) {
      srsHtmlUnsupported('html: image "$src"');
    }
    return src;
  }

  /// 空白处理 + 收尾：全空的段返回 null。
  SrsHtmlFlow? _finishFlow(List<SrsHtmlInline> inlines, SrsHtmlStyle style) {
    if (inlines.isEmpty) return null;
    bool prevSpace = true;
    SrsHtmlTextRun? lastText;
    final List<SrsHtmlInline> out = <SrsHtmlInline>[];
    for (final SrsHtmlInline r in inlines) {
      switch (r) {
        case SrsHtmlTextRun():
          switch (r.style.whiteSpace) {
            case SrsHtmlWhiteSpace.pre:
            case SrsHtmlWhiteSpace.preWrap:
              r.text = r.text.replaceAll('\r\n', '\n');
              prevSpace = r.text.endsWith('\n');
            case SrsHtmlWhiteSpace.preLine:
              String t = r.text
                  .replaceAll('\r\n', '\n')
                  .replaceAll(RegExp(r'[ \t\f]+'), ' ')
                  .replaceAll(RegExp(r' ?\n ?'), '\n');
              if (prevSpace && t.startsWith(' ')) t = t.substring(1);
              r.text = t;
              if (t.isNotEmpty) prevSpace = t.endsWith(' ') || t.endsWith('\n');
            case SrsHtmlWhiteSpace.normal:
            case SrsHtmlWhiteSpace.nowrap:
              String t = r.text.replaceAll(RegExp(r'[ \t\n\r\f]+'), ' ');
              if (prevSpace && t.startsWith(' ')) t = t.substring(1);
              r.text = t;
              if (t.isNotEmpty) prevSpace = t.endsWith(' ');
          }
          if (r.text.isEmpty) continue;
          lastText = r;
          out.add(r);
        case SrsHtmlBreakRun():
          _trimTrailing(lastText);
          lastText = null;
          prevSpace = true;
          out.add(r);
        default:
          lastText = null;
          prevSpace = false;
          out.add(r);
      }
    }
    _trimTrailing(lastText);
    out.removeWhere((SrsHtmlInline r) => r is SrsHtmlTextRun && r.text.isEmpty);
    // 块末尾的 `<br>` 不另起一行（浏览器同样不算）。
    if (out.length > 1 && out.last is SrsHtmlBreakRun) out.removeLast();
    if (out.isEmpty) return null;
    return SrsHtmlFlow(out, style);
  }

  void _trimTrailing(SrsHtmlTextRun? r) {
    if (r == null) return;
    final SrsHtmlWhiteSpace ws = r.style.whiteSpace;
    if (ws == SrsHtmlWhiteSpace.pre || ws == SrsHtmlWhiteSpace.preWrap) return;
    if (r.text.endsWith(' ')) r.text = r.text.substring(0, r.text.length - 1);
  }
}
