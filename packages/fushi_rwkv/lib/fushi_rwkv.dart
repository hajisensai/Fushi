/// native/fushi_rwkv（RWKV 排程推理：大模型 / SM56 小模型）的 FFI 绑定。
///
/// 硬依赖、没有 Dart 回退：库缺失或 ABI 不符抛 [FushiRwkvUnavailableError]。app 经 [RwkvWorker]
/// 在后台 isolate 里持有 runtime；[RwkvNativeRuntime] 是同步底层接口（测试 / 工具用）。
library;

export 'src/fushi_rwkv_library.dart';
export 'src/rwkv_native.dart';
export 'src/rwkv_rows.dart';
export 'src/rwkv_worker.dart';
