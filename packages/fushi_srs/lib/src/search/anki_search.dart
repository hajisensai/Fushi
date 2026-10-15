/// Anki 搜索语法子集（AnkiConnect 兼容层 findNotes / findCards / canAddNotes
/// 查重用）：解析 [parseAnkiSearch] + 求值 [matchesAnkiSearch]。
library;

export 'search_matcher.dart' show matchesAnkiSearch;
export 'search_node.dart';
export 'search_parser.dart' show parseAnkiSearch;
export 'search_text.dart' show ankiSearchStripHtml;
