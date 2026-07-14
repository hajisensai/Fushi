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
    'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'keygen',
    'link', 'meta', 'param', 'source', 'track', 'wbr',
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
