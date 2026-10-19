/// 服务端 ONNX 会话工厂的 GPU 显存预算：经 `nvidia-smi` 查。
///
/// 根因：上游 `FfiOnnxSessionFactory.deviceMemoryBudgetBytes()` 恒返回 null（FFI 后端
/// 没有 DXGI / CUDA 显存查询）。而 `AsrTranscriptionService.plan` 对带显存门槛的包
/// （日语视频用的 Parakeet：`fp32GpuMinBudgetBytes` = 4 GB）把「预算未知」一律判成
/// int8，int8 又只排 CPU EP——于是服务端的视频转写**有 N 卡、装了 GPU 版
/// onnxruntime 也永远跑 CPU int8**（2026-10-19 基准验收：K-ON 5 集识别稿读音 CER
/// 8.7%，原型同分段 fp32 是 8.3%）。app 侧走插件后端，查得到 DXGI 预算，不受影响。
///
/// 这里只补「预算」这一项（其余原样委托）：取 `nvidia-smi` 报的**可用**显存
/// （`memory.free`，与 app 的 DXGI「本进程可分配上限」同一语义的保守近似）。查不到
/// （没有 N 卡 / 驱动 / 命令）照旧返回 null，行为与之前一致。只在 ORT 报了 CUDA EP
/// 时才查：没有 CUDA EP 的 ORT 拿到预算也用不上 GPU。
library;

import 'package:fushi_asr_core/asr_core.dart' as asr;

/// 查第 [deviceId] 块 N 卡的可用显存（字节）；查不到返回 null。
typedef GpuMemoryBudgetQuery = Future<int?> Function(int deviceId);

/// 解析 `nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits` 的一行
/// （MiB）；看不懂返回 null。
int? parseNvidiaSmiFreeMib(String output) {
  for (final String raw in output.split('\n')) {
    final int? mib = int.tryParse(raw.trim());
    if (mib != null && mib > 0) return mib * 1024 * 1024;
  }
  return null;
}

/// 默认查询：跑 `nvidia-smi -i <deviceId>`（15 s 超时）。失败一律 null。
Future<int?> queryNvidiaFreeMemoryBytes(int deviceId) async {
  try {
    final asr.AsrProcessResult r = await asr
        .runAsrProcess('nvidia-smi', <String>[
          '-i',
          '$deviceId',
          '--query-gpu=memory.free',
          '--format=csv,noheader,nounits',
        ], timeout: const Duration(seconds: 15));
    if (r.exitCode != 0) return null;
    return parseNvidiaSmiFreeMib(r.stdout);
  } on Exception {
    return null;
  }
}

/// 给 [inner] 补上显存预算查询。
class ServerGpuBudgetOnnxFactory implements asr.OnnxSessionFactory {
  ServerGpuBudgetOnnxFactory(
    this.inner, {
    this.deviceId = 0,
    GpuMemoryBudgetQuery query = queryNvidiaFreeMemoryBytes,
  }) : _query = query;

  final asr.OnnxSessionFactory inner;
  final int deviceId;
  final GpuMemoryBudgetQuery _query;

  @override
  Future<asr.OnnxSession> createSession(
    String modelPath, {
    required List<asr.OnnxExecutionProvider> providers,
    void Function(asr.OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) => inner.createSession(
    modelPath,
    providers: providers,
    onProviderResolved: onProviderResolved,
    intraOpNumThreads: intraOpNumThreads,
    freeDimensionOverrides: freeDimensionOverrides,
  );

  @override
  Future<Set<asr.OnnxExecutionProvider>> availableAcceleratedProviders() =>
      inner.availableAcceleratedProviders();

  @override
  Future<int?> deviceMemoryBudgetBytes() async {
    final int? own = await inner.deviceMemoryBudgetBytes();
    if (own != null) return own;
    final Set<asr.OnnxExecutionProvider> providers = await inner
        .availableAcceleratedProviders();
    if (!providers.contains(asr.OnnxExecutionProvider.cuda)) return null;
    return _query(deviceId);
  }
}
