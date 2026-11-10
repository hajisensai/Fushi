/// 模板级「原生渲染」标记：非 Fushi 卡片（用户自建类型、Anki 导入类型）的模板可以标成
/// **一律走原生卡面**，原生 HTML 子集画不了的部分在卡面上就地标出来，而不是整张卡静默换成
/// 网页卡面（未标记的模板照旧：两面都画得全才原生，否则整面 WebView，见 srs_html_card.dart）。
///
/// - **标记写在模板正文里**：正面模板开头（可视化布局注释之后）一行 `<!--fushi-native-->`。
///   与可视化布局、Fushi 卡片区块布局同一原则——模板正文是唯一的数据来源，不另开存储键：
///   同步、导出 .apkg、在 Anki 里打开都只看 HTML，注释无害；不认识它的旧版本照常按 HTML 渲染
///   （向后兼容）。标记是模板级的：只看正面，背面跟随。
/// - 判据只有一处（[srsTemplateIsNative]），读的是**渲染后的问题面**：标记是正面模板最前面的
///   字面文本，渲染后仍在问题 HTML 开头，字段内容不可能排到它前面。
/// - 强制原生（[srsForcedNativeHtmlCard]）按顶层块逐块判：整面画得全就原样；否则把画不了的
///   块换成一条提示（写明第一句画不了的写法），样式表画不了时不用它并在卡面最前面提示。
///
/// 纯 Dart（不依赖 Flutter），可在任何 isolate 跑。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'package:fushi/src/srs/srs_html_card.dart';

/// 模板级原生渲染标记。
const String kSrsNativeTemplateMarker = '<!--fushi-native-->';

/// 正面开头：可选的可视化布局注释（srs_visual_template.dart）+ 原生标记（+ 紧跟的一个换行）。
final RegExp _nativeAtStart = RegExp(
  r'^(\s*(?:<!--fushi-visual:v1:[A-Za-z0-9_\-=]*-->\s*?)?)<!--\s*fushi-native\s*-->\r?\n?',
);

/// 正面开头的可视化布局注释。
final RegExp _visualAtStart = RegExp(
  r'^\s*<!--fushi-visual:v1:[A-Za-z0-9_\-=]*-->',
);

/// 正面模板（名字 / id 形式都行）或渲染后的问题面 [front] 是否带原生渲染标记。
bool srsTemplateIsNative(String front) => _nativeAtStart.hasMatch(front);

/// 去掉 [front] 开头的原生渲染标记（没有就原样）。
String srsStripTemplateNative(String front) =>
    front.replaceFirstMapped(_nativeAtStart, (Match m) => m.group(1)!);

/// 给正面模板 [front] 打上 / 去掉原生渲染标记：标记放在可视化布局注释之后（布局注释必须在
/// 模板最前面才认得出），没有布局注释就放在最前面。打两次与打一次相同。
String srsWithTemplateNative(String front, bool native) {
  final String plain = srsStripTemplateNative(front);
  if (!native) return plain;
  final RegExpMatch? visual = _visualAtStart.firstMatch(plain);
  if (visual == null) return '$kSrsNativeTemplateMarker\n$plain';
  final String rest = plain.substring(visual.end);
  return '${plain.substring(0, visual.end)}\n$kSrsNativeTemplateMarker'
      '${rest.startsWith('\n') ? rest : '\n$rest'}';
}

/// 强制原生渲染的结果：两面（一定能画）+ 画不了而被换成提示的原因（去重，编辑页列出来）。
class SrsForcedNativeCard {
  const SrsForcedNativeCard(this.card, this.reasons);

  final SrsHtmlCard card;

  /// 画不了的写法（`html: <table>`、`css: at-rule "@media …"` …）；空 = 两面原样画全。
  final List<String> reasons;
}

final Map<String, SrsForcedNativeCard> _memo = <String, SrsForcedNativeCard>{};

/// 一面 HTML [body] 在样式表 [css] 下原生画不画得了：画得了 null，否则第一句画不了的写法。
/// 明暗两种主题都要排得出来（与 [srsHtmlCardProbe] 同一口径）。
String? _probe(String body, String css, String? languageCode) {
  try {
    final SrsHtmlCardFace face = SrsHtmlCardFace.parse(
      body,
      css,
      languageCode: languageCode,
    );
    face.layout(dark: false, foreground: 0xFF000000);
    face.layout(dark: true, foreground: 0xFFFFFFFF);
    return null;
  } on SrsHtmlUnsupported catch (e) {
    return e.reason;
  }
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// 卡面上的提示块：只用原生子集里的写法（与可视化「加底框」块同一套内联样式）。
String srsNativeNoticeHtml(String text) =>
    '<div class="fushi-native-unsupported" style="margin:0.45em 0;'
    'padding:0.6em 0.9em;border-radius:12px;'
    'background:rgba(127,127,127,0.12);opacity:0.75;font-size:0.85em">'
    '${_escape(text)}</div>';

/// 把一面 HTML [body] 改写成原生一定画得了的样子：画得全就原样；否则按顶层块（可视化模板
/// 的 `.fushi-visual` 容器会往里展开一层，背面的 `{{FrontSide}}` 带进来的正面同理）逐块判，
/// 画不了的块换成 [notice] 给出的提示；逐块换完整面仍画不了（块之间的层叠关系才出问题）就
/// 整面换成一条提示。画不了的原因记进 [reasons]。
String _nativeFace(
  String body,
  String css,
  String? languageCode,
  String Function(String reason) notice,
  List<String> reasons,
) {
  final String? whole = _probe(body, css, languageCode);
  if (whole == null) return body;
  final dom.Document doc = html_parser.parse(
    '<!doctype html><html><head></head><body>$body</body></html>',
  );
  final StringBuffer lead = StringBuffer();
  // 解析器挪进 head 的（`<link>` / `<meta>` …）原生不认，也不能悄悄丢掉。
  for (final dom.Element e in doc.head?.children ?? const <dom.Element>[]) {
    final String reason = 'html: <${e.localName}>';
    reasons.add(reason);
    lead.write(srsNativeNoticeHtml(notice(reason)));
  }
  void walk(dom.Element parent) {
    for (final dom.Node node in parent.nodes.toList()) {
      if (node is! dom.Element) continue;
      if (node.classes.contains('fushi-visual')) {
        walk(node);
        continue;
      }
      final String? reason = _probe(node.outerHtml, css, languageCode);
      if (reason == null) continue;
      reasons.add(reason);
      node.replaceWith(
        html_parser
            .parseFragment(srsNativeNoticeHtml(notice(reason)))
            .children
            .first,
      );
    }
  }

  final dom.Element root = doc.body!;
  walk(root);
  final String rebuilt = '$lead${root.innerHtml}';
  if (_probe(rebuilt, css, languageCode) == null) return rebuilt;
  reasons.add(whole);
  return srsNativeNoticeHtml(notice(whole));
}

/// 带原生渲染标记的卡（[srsTemplateIsNative]）一律原生：两面按 [_nativeFace] 改写；样式表
/// [css] 本身画不了（at-rule、不认识的属性 …）时两面都不用它，并在每面最前面提示一句。
///
/// [notice] 把画不了的原因变成卡面上的提示文字（由调用方本地化）。按内容记忆最近 12 张。
SrsForcedNativeCard srsForcedNativeHtmlCard({
  required String question,
  required String answer,
  required String css,
  required String Function(String reason) notice,
  String? languageCode,
}) {
  final String key =
      '${languageCode ?? ''}\u0000${notice('')}\u0000$css\u0000$question'
      '\u0000$answer';
  final SrsForcedNativeCard? hit = _memo.remove(key);
  if (hit != null) {
    _memo[key] = hit;
    return hit;
  }
  final List<String> reasons = <String>[];
  String usedCss = css;
  String lead = '';
  final String? cssReason = _probe('', css, languageCode);
  if (cssReason != null) {
    reasons.add(cssReason);
    usedCss = '';
    lead = srsNativeNoticeHtml(notice(cssReason));
  }
  SrsHtmlCardFace face(String body) => SrsHtmlCardFace.parse(
    '$lead${_nativeFace(body, usedCss, languageCode, notice, reasons)}',
    usedCss,
    languageCode: languageCode,
  );
  final SrsForcedNativeCard result = SrsForcedNativeCard(
    SrsHtmlCard(face(question), face(answer)),
    List<String>.unmodifiable(<String>{...reasons}),
  );
  _memo[key] = result;
  if (_memo.length > 12) _memo.remove(_memo.keys.first);
  return result;
}
