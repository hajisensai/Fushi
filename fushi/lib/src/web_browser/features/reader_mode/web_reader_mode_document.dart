import 'dart:convert';

import 'package:fushi_web_core/fushi_web_core.dart';

/// 阅读模式的干净排版：正文来自网页小说同一个 Rust 提取器（[WebArticleExtractor]，
/// 站点规则 / readability / 文本密度三档），这里只把提取结果拼成一页 HTML 与配色，
/// 再生成「就地把当前文档正文换掉」的脚本。
///
/// 为什么就地换 `body` 而不是 `loadData` 一页新文档：浏览器标签页上已经装好的查词
/// 监听（挂在 `document` 上）、学习统计脚本都活在当前文档里，换 body 子树
/// 它们全部照常工作；新文档则要壳重新注入一遍，而且「存进书架」要的原页上下文
/// （下一章链接、站点规则）也会丢。退出阅读模式 = 重新加载原页。

/// 正文太短（导航页 / 登录页误判）时不进阅读模式。
const int kWebReaderModeMinChars = 40;

/// 阅读模式的配色（CSS 颜色串）。
class WebReaderModeTheme {
  const WebReaderModeTheme({
    required this.background,
    required this.text,
    required this.muted,
    required this.accent,
    required this.dark,
  });

  final String background;
  final String text;
  final String muted;
  final String accent;
  final bool dark;
}

/// 提取结果够不够做阅读模式。
bool webReaderModeAccepts(WebArticle article) =>
    article.xhtml.trim().isNotEmpty && article.chars >= kWebReaderModeMinChars;

final RegExp _imagePlaceholder = RegExp(
  '(src\\s*=\\s*)(["\'])${RegExp.escape(kWebArticleImagePlaceholderPrefix)}(\\d+)\\2',
);

String _attr(String s) => const HtmlEscape(HtmlEscapeMode.attribute).convert(s);
String _text(String s) => const HtmlEscape(HtmlEscapeMode.element).convert(s);

/// 把正文里的图片占位（`src="fushi-web-image:i"`）换回 [images] 第 i 项的真实地址；
/// 只认 http(s)，越界 / 别的协议的占位整个 `src` 换成空串（图不显示，不留可执行地址）。
String resolveWebArticleImages(String xhtml, List<String> images) =>
    xhtml.replaceAllMapped(_imagePlaceholder, (Match m) {
      final int? i = int.tryParse(m.group(3)!);
      final String? raw = i != null && i < images.length ? images[i] : null;
      final Uri? uri = raw == null ? null : Uri.tryParse(raw);
      final bool ok =
          uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
      return '${m.group(1)}"${ok ? _attr(raw!) : ''}"';
    });

/// 阅读模式正文（`body` 的内容）。
String buildWebReaderModeBody(WebArticle article, {String? siteName}) {
  final StringBuffer sb = StringBuffer('<article class="fushi-reader">');
  final String site = (article.workTitle ?? siteName ?? '').trim();
  sb.write('<header>');
  if (site.isNotEmpty && site != article.title.trim()) {
    sb.write('<p class="fushi-reader-site">${_text(site)}</p>');
  }
  if (article.title.trim().isNotEmpty) {
    sb.write('<h1>${_text(article.title.trim())}</h1>');
  }
  final String? author = article.author?.trim();
  if (author != null && author.isNotEmpty) {
    sb.write('<p class="fushi-reader-byline">${_text(author)}</p>');
  }
  sb.write('</header><section class="fushi-reader-body">');
  sb.write(resolveWebArticleImages(article.xhtml, article.images));
  sb.write('</section></article>');
  return sb.toString();
}

/// 阅读模式样式表（挂在 `html[data-fushi-reader]` 下，压过页面残留的内联样式）。
String buildWebReaderModeCss(WebReaderModeTheme theme) {
  final String bg = theme.background;
  final String fg = theme.text;
  final String muted = theme.muted;
  final String accent = theme.accent;
  return 'html[data-fushi-reader]{background:$bg!important;'
      'color-scheme:${theme.dark ? 'dark' : 'light'};}'
      'html[data-fushi-reader] body{margin:0 auto!important;'
      'padding:24px 20px 96px!important;max-width:42em!important;'
      'background:$bg!important;color:$fg!important;'
      'font-family:"Hiragino Mincho ProN","Yu Mincho","Noto Serif JP",'
      '"Noto Serif CJK JP",serif!important;font-size:1.1rem;line-height:1.9;'
      'overflow-wrap:anywhere;writing-mode:horizontal-tb!important;}'
      '.fushi-reader-site{color:$muted;font-size:.85em;margin:0 0 .4em;}'
      '.fushi-reader h1{font-size:1.5em;line-height:1.45;margin:0 0 .4em;}'
      '.fushi-reader-byline{color:$muted;font-size:.9em;margin:0 0 1.6em;}'
      '.fushi-reader p{margin:0 0 1em;}'
      '.fushi-reader img{max-width:100%;height:auto;display:block;'
      'margin:1em auto;}'
      '.fushi-reader a{color:$accent;}'
      '.fushi-reader blockquote{margin:0 0 1em;padding-left:1em;'
      'border-left:3px solid $accent;color:$muted;}'
      '.fushi-reader pre{white-space:pre-wrap;}'
      '.fushi-reader table{border-collapse:collapse;max-width:100%;}'
      '.fushi-reader td,.fushi-reader th{border:1px solid $muted;'
      'padding:.2em .5em;}';
}

/// 就地把当前文档换成阅读模式的脚本：正文先经 `DOMParser` 解析、剥掉一切可执行的
/// 东西（脚本 / 框架 / 表单 / 事件属性 / `javascript:` 地址 / 内联样式），页面自带的
/// 样式表全部摘掉（`id` 以 `fushi-` 开头的是本 app 注入的，留下），再换进 `body`。
String webReaderModeInstallScript({
  required String bodyHtml,
  required String css,
}) =>
    '''
(function(html, css){
  var doc = new DOMParser().parseFromString(
    '<!DOCTYPE html><html><body>' + html + '</body></html>', 'text/html');
  var bad = doc.body.querySelectorAll('script,style,link,iframe,frame,frameset,'
    + 'object,embed,form,input,button,textarea,select,meta,base,noscript,'
    + 'template,svg,math,video,audio');
  for (var i = 0; i < bad.length; i++) bad[i].remove();
  var all = doc.body.querySelectorAll('*');
  for (var j = 0; j < all.length; j++) {
    var el = all[j], attrs = Array.prototype.slice.call(el.attributes);
    for (var k = 0; k < attrs.length; k++) {
      var n = attrs[k].name.toLowerCase(), v = String(attrs[k].value).trim()
        .toLowerCase();
      if (n.indexOf('on') === 0 || n === 'style' || n === 'srcset' ||
          ((n === 'href' || n === 'src') &&
            (v.indexOf('javascript:') === 0 || v.indexOf('data:') === 0))) {
        el.removeAttribute(attrs[k].name);
      }
    }
  }
  var sheets = document.querySelectorAll('style,link[rel~="stylesheet"]');
  for (var s = 0; s < sheets.length; s++) {
    if (String(sheets[s].id || '').indexOf('fushi-') !== 0) sheets[s].remove();
  }
  var root = document.documentElement;
  root.removeAttribute('style');
  root.setAttribute('data-fushi-reader', '1');
  var body = document.body || root.appendChild(document.createElement('body'));
  var battrs = Array.prototype.slice.call(body.attributes);
  for (var b = 0; b < battrs.length; b++) body.removeAttribute(battrs[b].name);
  var nodes = [];
  for (var c = doc.body.firstChild; c; c = c.nextSibling) {
    nodes.push(document.importNode(c, true));
  }
  body.replaceChildren.apply(body, nodes);
  if (!document.querySelector('meta[name="viewport"]')) {
    var vp = document.createElement('meta');
    vp.name = 'viewport';
    vp.content = 'width=device-width, initial-scale=1';
    (document.head || root).appendChild(vp);
  }
  var st = document.getElementById('fushi-reader-css');
  if (!st) {
    st = document.createElement('style');
    st.id = 'fushi-reader-css';
    (document.head || root).appendChild(st);
  }
  st.textContent = css;
  window.scrollTo(0, 0);
  return true;
})(${jsonEncode(bodyHtml)}, ${jsonEncode(css)});
''';
