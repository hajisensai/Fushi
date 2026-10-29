/// Anki 搜索语法子集（浏览页、AnkiConnect 兼容层 findNotes / findCards / canAddNotes 查重）：Dart 解析
/// [parseAnkiSearch]，求值在 native/fushi_fsrs 的 Rust 实现（只有这一份）：浏览页与 AnkiConnect 走原生浏览会话
/// （store/browse.rs）；[SrsSearchCorpus] 是同一个内核的整批求值入口（由调用方给出求值对象）。
library;

export 'search_corpus.dart'
    show
        SrsSearchCorpus,
        SrsSearchFieldAliases,
        kSrsSearchKernelUnavailable,
        srsDupeNormBatch,
        srsSearchNodeJson;
export 'search_node.dart';
export 'search_parser.dart' show parseAnkiSearch;
