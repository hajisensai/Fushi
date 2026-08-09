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
  // `<tag>` open tag. Two ways this breaks Hibiki:
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
  static final RegExp _loadingAttrPattern =
      RegExp(r'\bloading\s*=', caseSensitive: false);
  static final RegExp _gaijiClassPattern = RegExp(
      r'''\bclass\s*=\s*(?:"[^"]*\bgaiji|'[^']*\bgaiji|gaiji)''',
      caseSensitive: false);

  /// TODO-perf（跨章·图片）：在**生成 HTML 时**就给正文插图标上 `loading="lazy"` /
  /// `decoding="async"`。
  ///
  /// 阅读器 JS（`initialize` 里 TODO-1074 那段）本来就想给每张 `<img>` 挂 lazy，理由写的
  /// 也正是「不再拖住 window.load」——但那段脚本是在 `onLoadStop`（即 `load` 事件**之后**）
  /// 注入的，浏览器早已按标签里的原始属性把整章图片全部读盘+解码完毕。换句话说那行 lazy
  /// 迟到了一整个加载周期，只是给一笔已经付掉的账贴了张标签。实测带插图的章 `nav.dcl`
  /// 15~20ms 而 `nav.load` 687~717ms，遮罩全程盖在这段等待上。
  ///
  /// 属性只有写进 HTML 源码才能影响本次加载，所以判定上移到 Dart 侧。保持 eager 的例外与
  /// JS 侧同款、且**更保守**（这里 eager 的集合是 JS 侧 eager 集合的超集，绝不会出现
  /// 「Dart 挂了 lazy 而 JS 想要 eager」的倒挂）：
  /// - [eagerAll] = true（纯图片章：整章就是几张整页插图，分页几何要靠它们真实撑开，见
  ///   TODO-1349）→ 整章一律 eager，原样返回。
  /// - `class` 含 `gaiji` 的内联小图参与文字排版几何，必须同步解码 → 跳过。
  /// - 已显式写了 `loading=` 的标签 → 尊重原书，跳过。
  ///
  /// 合并注入的前导插图（`.fushi-merged-image`）不经过这里——调用点在
  /// `_injectMergedChapterImages` **之前**，那些图天然保持 eager（TODO-1339）。
  static String markImagesLazy(String html, {bool eagerAll = false}) {
    if (eagerAll) return html;
    return html.replaceAllMapped(_imgTagPattern, (Match m) {
      final String whole = m.group(0)!;
      final String attrs = m.group(1) ?? '';
      if (_loadingAttrPattern.hasMatch(attrs)) return whole;
      if (_gaijiClassPattern.hasMatch(attrs)) return whole;
      return '<img loading="lazy" decoding="async"$attrs>';
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
