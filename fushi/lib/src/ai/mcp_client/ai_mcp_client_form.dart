/// MCP server 编辑页的多行文本 ↔ 结构化字段（纯函数，测试直接调）。
library;

/// `Key: Value` 每行一条 → 请求头。空行与没有 `:` 的行忽略；键去空白，值去首尾空白。
Map<String, String> parseMcpHeaderLines(String text) =>
    _parsePairs(text, separator: ':');

/// 请求头 → `Key: Value` 每行一条。
String formatMcpHeaderLines(Map<String, String> headers) => <String>[
  for (final MapEntry<String, String> e in headers.entries)
    '${e.key}: ${e.value}',
].join('\n');

/// `KEY=value` 每行一条 → 环境变量。
Map<String, String> parseMcpEnvLines(String text) =>
    _parsePairs(text, separator: '=');

/// 环境变量 → `KEY=value` 每行一条。
String formatMcpEnvLines(Map<String, String> env) => <String>[
  for (final MapEntry<String, String> e in env.entries) '${e.key}=${e.value}',
].join('\n');

/// 每行一个参数（空行忽略，行内空格保留——参数本身可以含空格）。
List<String> parseMcpArgLines(String text) => <String>[
  for (final String line in text.split(RegExp(r'\r?\n')))
    if (line.trim().isNotEmpty) line.trim(),
];

Map<String, String> _parsePairs(String text, {required String separator}) {
  final Map<String, String> out = <String, String>{};
  for (final String line in text.split(RegExp(r'\r?\n'))) {
    final int at = line.indexOf(separator);
    if (at <= 0) continue;
    final String key = line.substring(0, at).trim();
    if (key.isEmpty) continue;
    out[key] = line.substring(at + 1).trim();
  }
  return out;
}
