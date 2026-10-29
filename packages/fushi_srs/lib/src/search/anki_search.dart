/// Anki 搜索语法子集（浏览页、统计页筛选、AnkiConnect 兼容层 findNotes / findCards /
/// canAddNotes 查重）：Dart 解析 [parseAnkiSearch]，整批求值 [SrsSearchCorpus]
/// （native/fushi_fsrs 的 Rust 实现，只有这一份）。
library;

export 'search_corpus.dart'
    show
        SrsSearchCorpus,
        SrsSearchFieldAliases,
        SrsSearchFieldLoader,
        kSrsSearchKernelUnavailable,
        srsDupeNormBatch,
        srsSearchNodeJson;
export 'search_node.dart';
export 'search_parser.dart' show parseAnkiSearch;
