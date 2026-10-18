/// native/fushi_compute 的 FFI 绑定。各域（哈希 / 图像 / 文本匹配 / 加密）在 `src/<域>/`。
/// 加密域的原生库是硬依赖：缺失时抛 [FushiComputeUnavailableError]（见 [FushiComputeCrypto]），没有 Dart 回退。
library;

export 'src/crypto/fushi_compute_crypto.dart';
export 'src/fushi_compute_library.dart';
