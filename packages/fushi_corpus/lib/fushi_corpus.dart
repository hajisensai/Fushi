/// native/fushi_corpus（Rust 语料胖核心：「我库里的例句」的倒排索引与查询）的 FFI 绑定。
/// 硬依赖、没有 Dart 回退：库或符号缺失时抛 [FushiCorpusUnavailableError]。
library;

export 'src/corpus_models.dart';
export 'src/corpus_native.dart';
export 'src/fushi_corpus_library.dart';
