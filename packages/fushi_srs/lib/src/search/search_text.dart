/// Anki 搜索的文本工具：通配符转正则（rslib text.rs `to_custom_re`）与
/// 去 HTML（rslib text.rs `strip_html`）。
library;

/// 只转义正则语法字符（unicode 模式下对其它字符做 identity escape 是语法错误）。
String _escapeRegExp(String s) {
  final StringBuffer buf = StringBuffer();
  for (final int c in s.runes) {
    if (r'\^$.*+?()[]{}|/'.contains(String.fromCharCode(c))) buf.write(r'\');
    buf.writeCharCode(c);
  }
  return buf.toString();
}

/// Anki 通配文本 → 正则源码：`*` → `<wildcard>*`、`_` → `<wildcard>`、
/// `\*` / `\\` 为字面量、`\_` 为字面量下划线，其余字符全部转义。
String ankiGlobToRegExpSource(String text, {String wildcard = '.'}) {
  final StringBuffer buf = StringBuffer();
  final List<int> runes = text.runes.toList();
  for (int i = 0; i < runes.length; i++) {
    final int c = runes[i];
    if (c == 0x5C /* \ */ && i + 1 < runes.length) {
      final int next = runes[++i];
      switch (next) {
        case 0x5C:
          buf.write(r'\\');
        case 0x2A:
          buf.write(r'\*');
        case 0x5F:
          buf.write('_');
        default:
          buf.write(_escapeRegExp(String.fromCharCodes(<int>[c, next])));
      }
      continue;
    }
    switch (c) {
      case 0x2A:
        buf.write('$wildcard*');
      case 0x5F:
        buf.write(wildcard);
      default:
        buf.write(_escapeRegExp(String.fromCharCode(c)));
    }
  }
  return buf.toString();
}

/// 不区分大小写的通配正则；[anchored] 为 true 时整值匹配。
RegExp ankiGlobRegExp(String text, {bool anchored = true}) {
  final String source = ankiGlobToRegExpSource(text);
  return RegExp(
    anchored ? '^$source\$' : source,
    caseSensitive: false,
    unicode: true,
    dotAll: true,
  );
}

final RegExp _htmlPattern = RegExp(
  r'(<!--.*?-->)|(<style.*?>.*?</style>)|(<script.*?>.*?</script>)|(<.*?>)',
  caseSensitive: false,
  dotAll: true,
);

const Map<String, String> _namedEntities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
};

final RegExp _entityPattern = RegExp(
  r'&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z]+);',
);

/// 去掉 HTML 标签并解码实体（数字实体与常用命名实体；`&nbsp;` 解成空格）。
String ankiSearchStripHtml(String html) {
  final String stripped = html.replaceAll(_htmlPattern, '');
  if (!stripped.contains('&')) return stripped;
  return stripped.replaceAllMapped(_entityPattern, (Match m) {
    final String body = m.group(1)!;
    if (body.startsWith('#')) {
      final bool hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
      final int? code = int.tryParse(
        hex ? body.substring(2) : body.substring(1),
        radix: hex ? 16 : 10,
      );
      if (code == null || code > 0x10FFFF) return m.group(0)!;
      return code == 0xA0 ? ' ' : String.fromCharCode(code);
    }
    return _namedEntities[body] ?? m.group(0)!;
  });
}
