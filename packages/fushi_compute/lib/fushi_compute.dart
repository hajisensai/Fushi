/// native/fushi_compute 的 FFI 绑定。各域（哈希 / 图像 / 文本匹配）在 `src/<域>/`，
/// 库或该域的符号缺失时对应 API 返回 null，由调用方退回 Dart 实现。
library;

export 'src/fushi_compute_library.dart';
export 'src/image/fushi_compute_image.dart';
