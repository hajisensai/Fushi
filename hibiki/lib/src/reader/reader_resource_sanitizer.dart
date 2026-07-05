class ReaderResourceSanitizer {
  ReaderResourceSanitizer._();

  static final RegExp _epubPropertyPattern = RegExp(
    r'^([ \t]*)-epub-([^:;{}\r\n]+)[ \t]*:[ \t]*([^;{}\r\n]*)[ \t]*;',
    multiLine: true,
  );

  // Raw-text / escapable-raw-text HTML elements: when an EPUB ships them in
  // self-closing XHTML form (e.g. `<script .../>`) but the bytes are parsed as
  // text/html, the HTML5 tokenizer ignores the self-closing slash, enters the
  // element's "raw text" content model, and swallows everything up to the next
  // matching close tag — which never comes — blanking the whole page (BUG-079).
  // Convert those self-closing forms into explicit paired tags so the parser
  // closes them immediately and the body renders. Genuine void elements
  // (<br/>, <img/>, …) are NOT in this set and are left untouched.
  // The attribute portion matches whole quoted strings ("…" / '…') as single
  // tokens so a literal `/>` *inside* an attribute value (e.g.
  // `<script data-x="a/>b"></script>`) is NOT mistaken for the tag's
  // self-closing end — only a real trailing `/>` outside any quote triggers the
  // rewrite. Unquoted chars exclude `>`/quotes.
  static final RegExp _selfClosingRawTextPattern = RegExp(
    r'<(script|style|textarea|title|iframe|noscript|noframes|xmp|noembed)'
    '\\b((?:"[^"]*"|\'[^\']*\'|[^>"\'])*?)\\s*/\\s*>',
    caseSensitive: false,
  );

  static final RegExp _bodyOpenPattern =
      RegExp(r'<body[^>]*>', caseSensitive: false);

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

  /// Normalizes XHTML served as text/html so self-closing raw-text elements do
  /// not swallow the document body. Returns the input unchanged when no such
  /// element is present.
  static String sanitizeXhtml(String html) {
    return html.replaceAllMapped(_selfClosingRawTextPattern, (m) {
      final String tag = m.group(1)!;
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
