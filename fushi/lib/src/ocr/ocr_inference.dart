/// ONNX 推理会话抽象层。
///
/// 把 `flutter_onnxruntime` 包在窄接口后面：算法层（检测/识别/beam search）
/// 只依赖 [OcrSession] / [OcrTensor]，单元测试用 fake 实现即可，不需要真模型
/// 或 native 绑定。真实现见 `ocr_inference_ort.dart`。
library;

import 'dart:typed_data';

/// 支持的张量元素类型（本子系统只需要 float32 与 int64）。
enum OcrTensorType { float32, int64 }

/// 不可变张量：扁平数据 + 形状。
class OcrTensor {
  OcrTensor.float32(Float32List data, this.shape)
      : type = OcrTensorType.float32,
        floatData = data,
        intData = null {
    _checkLength(data.length);
  }

  OcrTensor.int64(Int64List data, this.shape)
      : type = OcrTensorType.int64,
        floatData = null,
        intData = data {
    _checkLength(data.length);
  }

  final OcrTensorType type;
  final List<int> shape;
  final Float32List? floatData;
  final Int64List? intData;

  int get elementCount => shape.fold<int>(1, (int acc, int dim) => acc * dim);

  void _checkLength(int length) {
    if (length != elementCount) {
      throw ArgumentError(
          'OcrTensor data length $length does not match shape $shape '
          '($elementCount elements)');
    }
  }
}

/// 一次可运行的 ONNX 会话。
abstract interface class OcrSession {
  /// 运行推理：输入/输出均为 名字 -> 张量。
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs);

  /// 释放 native 资源。
  Future<void> close();
}

/// 会话工厂：模型文件路径由调用方注入（模型下载管理不在本层）。
abstract interface class OcrSessionFactory {
  Future<OcrSession> createSession(
    String modelPath, {
    required List<OcrExecutionProvider> providers,
  });
}

/// 执行后端（execution provider）。
enum OcrExecutionProvider { cuda, directml, coreml, cpu }

/// 一次会话创建实际落到哪个执行后端，以及（若发生）降级原因。
///
/// 粒度就是插件边界能给出的粒度：`flutter_onnxruntime` 只回报「整张 provider
/// 列表被接受」或「被拒绝」，不告诉我们 ORT 内部最终选中的 EP。因此
/// [effective] 的语义是「本次真正提交给 ORT 的首选 provider」——列表被接受时
/// 是 [requested] 的首项，被拒绝并回退时是 [OcrExecutionProvider.cpu]。
///
/// 存在的唯一理由：降级路径必须显式可观测。把 GPU 静默换成 CPU 会让用户在
/// 整卷 OCR 这种耗时任务上误判性能，本仓不允许无声降级。
class OcrProviderResolution {
  const OcrProviderResolution({
    required this.requested,
    required this.effective,
    this.fallbackReason,
  });

  /// 调用方按平台策略请求的 provider 列表（首项为首选）。
  final List<OcrExecutionProvider> requested;

  /// 本次会话真正提交给 ORT 的首选 provider。
  final OcrExecutionProvider effective;

  /// 降级原因；null 表示未降级。
  final String? fallbackReason;

  bool get didFallBack => fallbackReason != null;

  @override
  String toString() {
    if (!didFallBack) return 'OcrProviderResolution(${effective.name})';
    final String from = requested.isEmpty ? 'none' : requested.first.name;
    return 'OcrProviderResolution($from -> ${effective.name}: $fallbackReason)';
  }
}

/// 模型种类：检测（单次前向）与识别（自回归解码）的 EP 策略不同。
enum OcrModelKind { detection, recognition }

/// 平台（纯枚举入参，保持 [selectOcrExecutionProviders] 可测纯函数）。
enum OcrPlatform { windows, macos, ios, linux, android }

/// 平台想要的**加速** EP 优先级（不含 CPU）。
///
/// 只表达「偏好」，不表达「可用」——真实可用性由调用方探测后交给
/// [selectOcrExecutionProviders] 求交集。把这两件事拆开是 BUG-2050 的根因修复：
/// 原先 Windows 分支直接假设 DirectML 可用（只有 CUDA 被真探测过），运行时里
/// 没有 DML 时每个任务都要白付一次注定失败的建会话再退 CPU。
///
/// 策略依据（用户拍板 + 本机实测）：
///
/// - **Windows 检测：只考虑 CUDA，不要 DirectML**（BUG-2050 实测拍板）。
///   我们出包用的检测器是 **int8** 量化的 RT-DETR-v2
///   （`detector-v4-s_int8.onnx`），它在 ORT 1.22.0 的 DML EP 上**根本建不出
///   会话**——挂在 DML 算子授权层
///   `DmlExecutionProvider/src/MLOperatorAuthorImpl.cpp(2851)`，
///   `E_INVALIDARG (0x80070057)`，错误码 `ORT_RUNTIME_EXCEPTION`。
///
///   2026-09-02 本机实测（RTX 5090 / ORT 1.22.0 DirectML build / DirectML
///   1.15.4 / 同一 640×640 输入、1 次预热 + 3 次取最优）：
///
///   | 模型 | DML 建会话 | DML 稳态 | CPU 建会话 | CPU 稳态 |
///   |---|---|---|---|---|
///   | **int8（出包用）** | **❌ 失败，白付 1547ms** | — | 734ms | **81.5ms** |
///   | fp32（同架构对照） | ✅ 2957ms | 21.6ms | 1461ms | 419.4ms |
///
///   对照组是关键：fp32 档在同一台机器、同一个运行时上**建得起来且比 CPU 快
///   19.4 倍**，`D3D12CreateDevice` 也正常——所以这不是显卡、不是 WDDM 状态、
///   不是打包问题，**变量精确就是 int8 量化**。
///
///   旧注释里那句「DirectML 实测比 CPU 快 ~25 倍」量的就是 **fp32 档**（19.4x
///   与之同量级）。后来检测器换成 int8 小档（11MB vs 168MB，且 int8 在 CPU 上
///   反而比 fp32 快 5 倍：81.5ms vs 419.4ms），加速前提就没了，那句话却留了
///   下来——于是每个任务白付一次 1.5 秒的失败建会话。**别再凭那句话把
///   DirectML 加回来**：换模型才是重新评估的前提，要加先用 BUG-2050 里的探针
///   在真机上重新拿数。
/// - Windows 识别：只考虑 CUDA —— 实测 DirectML 对自回归逐步解码是负优化
///   （每步 GPU 往返开销远大于小 batch 计算本身）。
///
///   注意：检测与识别当前**恰好**都只剩 CUDA，但理由完全不同（检测是模型建不
///   起来，识别是架构上的负优化）。所以 [kind] 这个轴保留——任一条前提变了它们
///   就会重新分叉。
/// - **macOS / iOS：不要任何加速 EP**（BUG-1613）。这里曾经按 Windows 的
///   类比给检测选 CoreML，但那段分支写下时 Apple 的 ORT native 整个被 gate 掉，
///   从未被执行过。2026-08-14 打开 Apple 本地 OCR 后真机对拍（同一页、1 次预热
///   + 3 次稳态取中位）：
///
///   | 平台 | EP | 检出 | 建会话 | 稳态/页 |
///   |---|---|---|---|---|
///   | macOS | CoreML | 4/4 | 4248ms | 237ms |
///   | macOS | CPU | 4/4 | 79ms | **148ms** |
///   | iOS (A13) | CoreML | **0/0 ❌** | 9269ms | 1491ms |
///   | iOS (A13) | CPU | 4/4 ✅ | 174ms | **381ms** |
///
///   检测模型是 int8 量化的 RT-DETR-v2；ORT 的 CoreML EP 把它交给 ANE 后在 iOS
///   上**静默算出空结果**——不抛异常、不触发 provider 回退，`onProviderResolved`
///   照报 `effective=coreml, fallback=null`，所以 BUG-1163 那套降级可观测性
///   完全照不到它。CPU 两端都又快又对，CoreML 在任何页数下都追不平。
///   别再凭直觉把 CoreML 加回来——要加先在真机上拿数，
///   `integration_test/manga_ocr_volume_e2e_itest.dart` 是现成的量具（它就是
///   抓到本 bug 的那条测试：CoreML 下它检出 0 块）。
/// - Linux / Android：不要任何加速 EP。
List<OcrExecutionProvider> acceleratedProviderPreference({
  required OcrModelKind kind,
  required OcrPlatform platform,
}) {
  switch (platform) {
    case OcrPlatform.windows:
      // 检测与识别当前**恰好**都只剩 CUDA，所以这里不按 [kind] 分支——两条
      // 返回同一个值的分支只是噪音。它们排除 DirectML 的理由不同（检测是 int8
      // 模型建不出会话，识别是自回归解码的架构性负优化，见上），任一条前提变了
      // 就在这里重新分叉，[kind] 为此保留在签名里。
      return const <OcrExecutionProvider>[OcrExecutionProvider.cuda];
    // BUG-1613：Apple 两端与 linux/android 同档，一个加速 EP 都不要（实测见上表）。
    case OcrPlatform.macos:
    case OcrPlatform.ios:
    case OcrPlatform.linux:
    case OcrPlatform.android:
      return const <OcrExecutionProvider>[];
  }
}

/// 按平台偏好与**本机真实可用的** EP 求交集，产出提交给 ORT 的 provider 列表。
///
/// 取 [acceleratedProviderPreference] 里第一个真实可用的加速 EP，后面永远缀一个
/// CPU 兜底；一个都不可用就返回纯 CPU。CPU 不参与探测——它永远在，也永远是
/// 最后一档，所以这里没有「CPU 可不可用」这种特殊情况。
///
/// [availableProviders] 是本机 ORT 运行时**编译进来**的加速 EP 集合，由调用方
/// 探测（`OrtOcrSessionFactory.availableAcceleratedProviders`），保持本函数无 IO。
///
/// 它是**必要不充分**条件：EP 编译进来了不代表此刻真能建出会话——DirectML 还要
/// 能建出 D3D12 设备，CUDA 还要有驱动和可用显卡。所以防线是两层，缺一不可：
/// 本函数负责「别去请求一个根本不存在的 EP」（BUG-2050），运行期真失败由
/// `createOcrSessionWithProviderFallback` 退到 CPU（BUG-1149 / BUG-1968）。
List<OcrExecutionProvider> selectOcrExecutionProviders({
  required OcrModelKind kind,
  required OcrPlatform platform,
  required Set<OcrExecutionProvider> availableProviders,
}) {
  final List<OcrExecutionProvider> preference = acceleratedProviderPreference(
    kind: kind,
    platform: platform,
  );
  for (final OcrExecutionProvider candidate in preference) {
    if (!availableProviders.contains(candidate)) continue;
    return <OcrExecutionProvider>[candidate, OcrExecutionProvider.cpu];
  }
  return const <OcrExecutionProvider>[OcrExecutionProvider.cpu];
}
