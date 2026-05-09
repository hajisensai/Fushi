class ReaderResourceSanitizer {
  ReaderResourceSanitizer._();

  static final RegExp _epubPropertyPattern = RegExp(
    r'^([ \t]*)-epub-([^:;{}\r\n]+)[ \t]*:[ \t]*([^;{}\r\n]*)[ \t]*;',
    multiLine: true,
  );

  static String sanitizeCss(String css) {
    return css.replaceAllMapped(_epubPropertyPattern, (Match m) {
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
