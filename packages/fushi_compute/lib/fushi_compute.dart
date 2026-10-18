/// native/fushi_compute 的 FFI 绑定。各域（哈希 / 图像 / 文本匹配）在 `src/<域>/`，
/// 硬依赖、没有 Dart 回退：库或某域符号缺失时抛 [FushiComputeUnavailableError]。
library;

export 'src/fushi_compute_library.dart';
export 'src/hash/ffc_hash.dart';
export 'src/parse/study_chars.dart';
