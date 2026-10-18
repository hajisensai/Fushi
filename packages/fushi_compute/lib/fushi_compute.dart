/// native/fushi_compute 的 FFI 绑定。各域（哈希 / 图像 / OCR 后段 / TS 解复用 / 文本匹配）在 `src/<域>/`，
/// 硬依赖、没有 Dart 回退：库或某域符号缺失时抛 [FushiComputeUnavailableError]。
library;

export 'src/fushi_compute_library.dart';
export 'src/hash/ffc_hash.dart';
export 'src/image/fushi_compute_bitmap_subtitle.dart';
export 'src/image/fushi_compute_image.dart';
export 'src/ocr/fushi_compute_ocr.dart';
export 'src/ts/fushi_compute_ts.dart';
