class ReaderResourceSanitizer {
  ReaderResourceSanitizer._();

  static final RegExp _epubPropertyPattern = RegExp(
    r'^([ \t]*)-epub-([^:;{}\r\n]+)[ \t]*:[ \t]*([^;{}\r\n]*)[ \t]*;',
    multiLine: true,
  );

  // HTML5 void elements: the ONLY tags whose self-closing `/>` form is valid in
  // text/html. Everything else that ships self-closed in XHTML must be expanded
  // to a paired tag (see [_selfClosingElementPattern] / [sanitizeXhtml]).
  static const Set<String> _voidElements = <String>{
    'area',
    'base',
    'br',
    'col',
    'embed',
    'hr',
    'img',
    'input',
    'keygen',
    'link',
    'meta',
    'param',
    'source',
    'track',
    'wbr',
  };

  // XHTML served as text/html: the HTML5 tokenizer IGNORES the self-closing
  // slash on every NON-void element, so `<tag .../>` becomes an unclosed
  // `<tag>` open tag. Two ways this breaks Fushi:
  //  • BUG-079: raw-text elements (`<script/>`, `<style/>`, `<title/>`, …) enter
  //    their "raw text" content model and swallow everything up to the next
  //    matching close tag — which never comes — blanking the whole page.
  //  • BUG-737: an active formatting element, above all `<a id="toc-N"/>` (the
  //    per-chapter anchor common in Japanese publisher EPUBs), stays open and,
  //    via the HTML adoption-agency reconstruction, wraps ALL following prose in
  //    an `<a>`. The reader's tap-lookup entry (`selectText`) then bails on
  //    `elementFromPoint(x,y).closest('a')` → the whole chapter becomes
  //    un-lookup-able (other, XML-aware readers parse `<a/>` as empty; repacking
  //    the EPUB re-serializes it closed, which is why that "fixes" lookup).
  // Fix once for the whole CLASS: rewrite every self-closing non-void element to
  // an explicit paired tag, which in XHTML means exactly the same empty element.
  // Void elements (<br/>, <img/>, …) keep their self-closing form.
  // The attribute portion matches whole quoted strings ("…" / '…') as single
  // tokens so a literal `/>` *inside* an attribute value (e.g.
  // `<a href="a/>b"></a>`) is NOT mistaken for the tag's self-closing end — only
  // a real trailing `/>` outside any quote triggers the rewrite. Unquoted chars
  // exclude `>`/quotes.
  static final RegExp _selfClosingElementPattern = RegExp(
    r'<([a-zA-Z][a-zA-Z0-9:-]*)'
    '\\b((?:"[^"]*"|\'[^\']*\'|[^>"\'])*?)\\s*/\\s*>',
    caseSensitive: false,
  );

  static final RegExp _bodyOpenPattern =
      RegExp(r'<body[^>]*>', caseSensitive: false);

  // 属性部分与 [_selfClosingElementPattern] 同款：把整段引号串（"…" / '…'）当单个
  // token，这样属性值里的字面 `>`（如 `alt="a>b"`）不会被误当成标签结束。
  static final RegExp _imgTagPattern = RegExp(
    '<img\\b((?:"[^"]*"|\'[^\']*\'|[^>"\'])*)>',
    caseSensitive: false,
  );
  // 引号串整段先被第一组吃掉（原样保留），属性值里的 `loading=` 字样就不会被误删；
  // 只有落在引号外的 ` loading=…` 才进第二组。
  static final RegExp _loadingAttrPattern = RegExp(
    '("[^"]*"|\'[^\']*\')|(\\s+loading\\s*=\\s*(?:"[^"]*"|\'[^\']*\'|[^\\s>"\']+))',
    caseSensitive: false,
  );

  /// 去掉正文 `<img>` 上原书自带的 `loading` 属性，让所有插图按浏览器默认（eager）
  /// 加载。阅读器三种视图的章节几何（分页 maxScroll、章首章末落点、跨章判定、VN 屏
  /// 切分）都要靠每张图的真实尺寸：`loading="lazy"` 的图在离视口远的分页列 / 脱离文档
  /// 的 VN 源树里永远不会加载，保持 0 尺寸，章节被算短，用户还没看完插图就被判到章末。
  static String stripImageLoadingAttributes(String html) {
    return html.replaceAllMapped(_imgTagPattern, (Match m) {
      final String attrs = m.group(1) ?? '';
      final String stripped = attrs.replaceAllMapped(
        _loadingAttrPattern,
        (Match a) => a.group(1) ?? '',
      );
      final String whole = m.group(0)!;
      // `<img` / `<IMG`：保留原书的标签名大小写。
      return stripped == attrs ? whole : '${whole.substring(0, 4)}$stripped>';
    });
  }

  /// TODO-1174: insert [imagesHtml] immediately after the document's `<body>`
  /// open tag, so merged single-image chapters render at the very *top* of the
  /// absorbing text chapter's flow (a standalone illustration belongs to the
  /// *beginning* of the chapter it introduces, not the tail of the previous
  /// one). Returns [html] unchanged when [imagesHtml] is empty; when no `<body>`
  /// open tag is present, prepends the images before the whole document.
  static String injectImagesAfterBodyOpen(String html, String imagesHtml) {
    if (imagesHtml.isEmpty) return html;
    final String block = '\n$imagesHtml\n';
    final RegExpMatch? match = _bodyOpenPattern.firstMatch(html);
    if (match != null) {
      return '${html.substring(0, match.end)}$block${html.substring(match.end)}';
    }
    return '$block$html';
  }

  static final RegExp _headOpenPattern =
      RegExp('<head[^>]*>', caseSensitive: false);
  static final RegExp _headClosePattern =
      RegExp(r'</head\s*>', caseSensitive: false);

  /// Injects the reader's head markup into a served chapter document:
  /// [headStart] right after `<head>` (the FOUC cloak must apply before any
  /// book CSS paints) and [headEnd] right before `</head>`, so reader styles
  /// win `!important` ties against the book's CSS and a reader viewport meta
  /// comes after any book-supplied one (WebKit applies the last viewport meta).
  /// Without a `</head>` both go after `<head>`; without a `<head>` both are
  /// prepended to the whole document.
  static String injectReaderHead(
    String html, {
    required String headStart,
    required String headEnd,
  }) {
    final RegExpMatch? headOpen = _headOpenPattern.firstMatch(html);
    final RegExpMatch? headClose = _headClosePattern.firstMatch(html);
    if (headOpen != null && headClose != null) {
      return '${html.substring(0, headOpen.end)}\n$headStart'
          '${html.substring(headOpen.end, headClose.start)}\n$headEnd\n'
          '${html.substring(headClose.start)}';
    }
    if (headOpen != null) {
      return '${html.substring(0, headOpen.end)}\n$headStart\n$headEnd'
          '${html.substring(headOpen.end)}';
    }
    return '$headStart\n$headEnd\n$html';
  }

  /// Normalizes XHTML served as text/html so a self-closing NON-void element
  /// (`<script/>` blanking the page — BUG-079; `<a id=".."/>` wrapping the whole
  /// chapter's prose and killing tap-lookup — BUG-737) becomes an explicit
  /// paired tag, i.e. the same empty element the XHTML author intended. Void
  /// elements (`<br/>`, `<img/>`, …) keep their self-closing form. Returns the
  /// input unchanged when no self-closing non-void element is present.
  static String sanitizeXhtml(String html) {
    return html.replaceAllMapped(_selfClosingElementPattern, (m) {
      final String tag = m.group(1)!;
      if (_voidElements.contains(tag.toLowerCase())) {
        return m.group(0)!; // genuine void element — keep self-closing
      }
      final String attrs = m.group(2)!;
      return '<$tag$attrs></$tag>';
    });
  }

  static String sanitizeCss(String css) {
    return css.replaceAllMapped(_epubPropertyPattern, (m) {
      final String indent = m.group(1)!;
      final String property = m.group(2)!.trim();
      final String value = m.group(3)!.trim();

      switch (property) {
        case 'writing-mode':
          return ''; // globally controlled by reader
        case 'line-break':
        case 'word-break':
        case 'hyphens':
          return '$indent-webkit-$property: $value;\n$indent$property: $value;';
        case 'text-combine':
          return '$indent-webkit-text-combine: $value;\n${indent}text-combine-upright: all;';
        case 'text-emphasis-style':
        case 'text-emphasis-color':
          return '$indent-webkit-$property: $value;\n$indent$property: $value;';
        default:
          return '$indent$property: $value;';
      }
    });
  }
}
